import SwiftUI
import ServiceManagement

// MARK: - Data

struct Window: Decodable { let utilization: Double; let resets_at: String? }
struct Limit: Decodable {
    struct Model: Decodable { let display_name: String? }
    struct Scope: Decodable { let model: Model? }
    let kind: String; let percent: Double?; let resets_at: String?; let scope: Scope?
}
struct Usage: Decodable {
    struct ScopedShare: Decodable { let limit_index: Int; let used_percent_of_weekly: Double? }
    let five_hour: Window?; let seven_day: Window?; let limits: [Limit]?; let weekly_scoped_shares: [ScopedShare]?
    // Real share (0...1) of this week's usage that went to the model-scoped limit, e.g. ("Fable", 0.74).
    // Skipped below 10% weekly usage: the API reports whole percents, so the ratio is too noisy there.
    func scopedShare() -> (name: String, share: Double)? {
        guard let w = seven_day?.utilization, w >= 10, let s = weekly_scoped_shares?.first,
              let used = s.used_percent_of_weekly, let limits, limits.indices.contains(s.limit_index),
              let name = limits[s.limit_index].scope?.model?.display_name else { return nil }
        return (name, min(max(used / w, 0.01), 0.99))
    }
    // Model-scoped weekly cap, e.g. "Fable". nil when the plan has none.
    func weekly(model: String) -> Window? {
        limits?.first { $0.kind == "weekly_scoped" && $0.scope?.model?.display_name == model }
            .map { Window(utilization: $0.percent ?? 0, resets_at: $0.resets_at) }
    }
}
struct Creds: Decodable { let accessToken: String; let subscriptionType: String? }
struct Msg: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

// Token that Claude Code keeps in the Keychain. Going through /usr/bin/security avoids a Keychain prompt.
func readCredentials() throws -> Creds {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw Msg("No Claude Code login found") }
    struct Wrap: Decodable { let claudeAiOauth: Creds }
    return try JSONDecoder().decode(Wrap.self, from: data).claudeAiOauth
}

func parseDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    // API sends microseconds; ISO8601DateFormatter can't parse those, so drop the fraction.
    return ISO8601DateFormatter().date(from: s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
}

func resetText(_ s: String?, now: Date = Date()) -> String {
    guard let d = parseDate(s) else { return " " }
    let secs = Int(d.timeIntervalSince(now))
    if secs <= 0 { return "Resetting…" }
    if secs < 86400 { return String(format: "Resets in %dh%02dm", secs / 3600, secs % 3600 / 60) }
    let f = DateFormatter(); f.dateFormat = "EEE HH:mm"
    return "Resets " + f.string(from: d)
}

// Weekly % at the start of today. The API has no daily number, so "today" = current - this.
// ponytail: counts from the first reading of the day; usage before the app's first refresh today
// (Mac off, other devices) and usage before a same-day weekly reset are missed.
func todayBase(current w: Double, savedDay: Double, savedBase: Double, today: Double) -> Double {
    if savedDay != today { return w }   // first reading today
    if w < savedBase { return 0 }       // weekly limit reset today
    return savedBase
}

// MARK: - Local breakdown (Claude Code transcripts)

struct Slice: Identifiable { let name: String; let pct: Double; var id: String { name } }
struct Breakdown { var models: [Slice] = []; var projects: [Slice] = [] }
struct Entry { let ts: String; let model: String; let effort: String?; let cost: Double }

// $ per MTok (input, output, cache read). Cache writes cost 1.25x input (5 min) or 2x input (1 hour).
// ponytail: API list prices stand in for the plan-limit formula, which isn't public, so shares are estimates.
// List prices alone put Fable at 59% when the API said 74%, so breakdown() rescales the scoped model
// to the API's real share when it is known. Unknown models fall back to Opus rates.
func rates(_ model: String) -> (inp: Double, out: Double, read: Double) {
    if model.contains("fable") || model.contains("mythos") { return (8, 40, 0.2) }
    if model.contains("sonnet") { return (2, 10, 0.1) }
    if model.contains("haiku") { return (0.1, 0.5, 0.01) }
    return (4, 20, 0.2)
}

// "claude-fable-5-2" + "xhigh" -> "Fable 5.2 (xHigh)"
func modelLabel(_ model: String, effort: String?) -> String {
    let parts: [String] = model.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init).filter { $0.count < 8 }
    var name = parts.first?.capitalized ?? model
    let ver = parts.dropFirst().joined(separator: ".")
    if !ver.isEmpty { name += " " + ver }
    guard let e = effort else { return name }
    return "\(name) (\(e == "xhigh" ? "xHigh" : e.capitalized))"
}

// Largest `limit` shares in percent; everything else is folded into "Other".
func top(_ d: [String: Double], limit: Int = 5) -> [Slice] {
    let total = d.values.reduce(0, +)
    guard total > 0 else { return [] }
    let sorted = d.sorted { $0.value > $1.value }
    var out = sorted.prefix(limit).map { Slice(name: $0.key, pct: $0.value / total * 100) }
    let rest = sorted.dropFirst(limit).reduce(0) { $0 + $1.value }
    if rest > 0 { out.append(Slice(name: "Other", pct: rest / total * 100)) }
    return out
}

// Reads ~/.claude/projects/**/*.jsonl. Only sees Claude Code on this Mac (not claude.ai chat or other machines).
final class Transcripts: @unchecked Sendable {
    private let lock = NSLock()
    // Parsed files keyed by path; a file is re-read only when its mtime changes.
    private var cache: [String: (mtime: Date, cwd: String?, entries: [String: Entry])] = [:]
    private static let needle = Data(#""type":"assistant""#.utf8)

    private static func num(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }

    static func parse(_ url: URL) -> (cwd: String?, entries: [String: Entry]) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return (nil, [:]) }
        var cwd: String?
        var out: [String: Entry] = [:]
        for line in data.split(separator: 0x0A) where line.range(of: needle) != nil {
            guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  d["type"] as? String == "assistant",
                  let ts = d["timestamp"] as? String,
                  let m = d["message"] as? [String: Any],
                  let model = m["model"] as? String, model.hasPrefix("claude"),
                  let u = m["usage"] as? [String: Any] else { continue }
            if cwd == nil { cwd = d["cwd"] as? String }
            let r = rates(model)
            let cc = u["cache_creation"] as? [String: Any]
            let w1h = cc.map { num($0, "ephemeral_1h_input_tokens") } ?? 0
            let w5m = cc.map { num($0, "ephemeral_5m_input_tokens") } ?? num(u, "cache_creation_input_tokens")
            var cost = num(u, "input_tokens") * r.inp + num(u, "output_tokens") * r.out
                + num(u, "cache_read_input_tokens") * r.read + (w5m * 1.25 + w1h * 2) * r.inp
            if u["speed"] as? String == "fast" { cost *= 2 }
            // A streamed message is logged several times under one id; the last line has the final token counts.
            let id = (m["id"] as? String) ?? (d["requestId"] as? String) ?? (d["uuid"] as? String) ?? ts
            out[id] = Entry(ts: ts, model: model, effort: d["effort"] as? String, cost: cost)
        }
        return (cwd, out)
    }

    func breakdown(since start: Date, calibrate: (name: String, share: Double)? = nil, root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")) -> Breakdown {
        lock.lock(); defer { lock.unlock() }
        var files: [(url: URL, mtime: Date)] = []
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let u as URL in en where u.pathExtension == "jsonl" {
                if let mt = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, mt >= start {
                    files.append((u, mt))
                }
            }
        }
        // Session files before their subagent files, so the project name comes from the session's launch folder.
        files.sort { $0.url.pathComponents.count < $1.url.pathComponents.count }
        let live = Set(files.map { $0.url.path })
        cache = cache.filter { live.contains($0.key) }

        // Timestamps are all UTC ISO-8601, so the first 19 chars compare correctly as strings.
        let startStr = ISO8601DateFormatter().string(from: start).prefix(19)
        var names: [String: String] = [:]
        var merged: [String: (entry: Entry, proj: String)] = [:]
        for f in files {
            let key = f.url.path
            if cache[key]?.mtime != f.mtime {
                let p = Self.parse(f.url)
                cache[key] = (f.mtime, p.cwd, p.entries)
            }
            guard let c = cache[key] else { continue }
            let proj = String(key.dropFirst(root.path.count + 1).split(separator: "/").first ?? "?")
            if names[proj] == nil, let cwd = c.cwd { names[proj] = (cwd as NSString).lastPathComponent }
            for (id, e) in c.entries where e.ts.prefix(19) >= startStr { merged[id] = (e, proj) }
        }
        // Rescale the scoped model (e.g. Fable) so its total share matches what the API reports.
        let scoped = calibrate?.name.lowercased()
        var scale = 1.0
        if let c = calibrate, let scoped {
            let f = merged.values.reduce(0) { $0 + ($1.entry.model.contains(scoped) ? $1.entry.cost : 0) }
            let o = merged.values.reduce(0) { $0 + $1.entry.cost } - f
            if f > 0, o > 0 { scale = c.share * o / ((1 - c.share) * f) }
        }
        var byModel: [String: Double] = [:], byProj: [String: Double] = [:]
        for v in merged.values {
            let cost = v.entry.cost * (scoped.map { v.entry.model.contains($0) } == true ? scale : 1)
            byModel[modelLabel(v.entry.model, effort: v.entry.effort), default: 0] += cost
            byProj[names[v.proj] ?? v.proj, default: 0] += cost
        }
        return Breakdown(models: top(byModel), projects: top(byProj))
    }
}

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    @Published var usage: Usage?
    @Published var plan = ""
    @Published var error: String?
    @Published var updated: Date?
    @Published var todayWeekly: Double?
    @Published var breakdown = Breakdown()
    private let transcripts = Transcripts()
    // Plain @Published (not @State): the Command Line Tools SDK ships without the SwiftUI macro plugin.
    @Published var atLogin = SMAppService.mainApp.status == .enabled {
        didSet { try? atLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }

    init() {
        Task { while true { await refresh(); try? await Task.sleep(for: .seconds(300)) } }
    }

    var label: String {
        func pct(_ w: Window?) -> String { w.map { "\(Int($0.utilization.rounded()))%" } ?? "–" }
        return "✱ \(pct(usage?.five_hour)) · W \(pct(usage?.seven_day))"
    }

    func refresh() async {
        do {
            let creds = try readCredentials()
            plan = creds.subscriptionType?.capitalized ?? ""
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw Msg(code == 401 ? "Token expired – run Claude Code once" : "HTTP \(code)") }
            usage = try JSONDecoder().decode(Usage.self, from: data)
            if let w = usage?.seven_day?.utilization {
                // Saved in UserDefaults so an app restart doesn't reset today's count.
                let d = UserDefaults.standard
                let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
                let base = todayBase(current: w, savedDay: d.double(forKey: "day"), savedBase: d.double(forKey: "base"), today: today)
                d.set(today, forKey: "day"); d.set(base, forKey: "base")
                todayWeekly = w - base
            }
            updated = Date()
            error = nil
        } catch {
            self.error = "\(error)"
        }
        // Same 7-day window as the weekly limit. Runs off the main thread: transcripts can be hundreds of MB.
        let start = (parseDate(usage?.seven_day?.resets_at) ?? Date()).addingTimeInterval(-7 * 86400)
        let t = transcripts
        let cal = usage?.scopedShare()
        breakdown = await Task.detached { t.breakdown(since: start, calibrate: cal) }.value
    }
}

// MARK: - UI

struct Row: View {
    let title: String
    let w: Window?
    var extra: String? = nil
    var body: some View {
        let u = w?.utilization ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(w == nil ? "–" : "\(Int(u.rounded()))%").bold()
            }
            ProgressView(value: min(u / 100, 1))
                .tint(u >= 90 ? .red : u >= 70 ? .orange : .blue)
            Text(resetText(w?.resets_at) + (extra.map { " · " + $0 } ?? "")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct Shares: View {
    let title: String
    let items: [Slice]
    let weekly: Double   // weekly limit used, in percent; each share is shown as its part of this
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach(items) { s in
                HStack {
                    Text(s.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    let p = s.pct * weekly / 100
                    Text(String(format: p < 10 ? "%.1f%%" : "%.0f%%", p)).monospacedDigit()
                }.font(.callout)
            }
        }
    }
}

struct Panel: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(m.plan.isEmpty ? "Claude" : "Claude · \(m.plan)").font(.headline)
                Spacer()
                Button { Task { await m.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }
            if let e = m.error { Text(e).font(.caption).foregroundStyle(.red) }
            Row(title: "5-hour session", w: m.usage?.five_hour)
            Row(title: "Weekly", w: m.usage?.seven_day, extra: m.todayWeekly.map { "Today +\(Int($0.rounded()))%" })
            if let f = m.usage?.weekly(model: "Fable") { Row(title: "Weekly · Fable", w: f) }
            if !m.breakdown.models.isEmpty, let w = m.usage?.seven_day?.utilization {
                Divider()
                let used = "Weekly \(Int(w.rounded()))% by"
                Shares(title: "\(used) model · est.", items: m.breakdown.models, weekly: w)
                Shares(title: "\(used) project · est.", items: m.breakdown.projects, weekly: w)
            }
            Divider()
            HStack {
                Text(m.updated.map { "Updated " + $0.formatted(date: .omitted, time: .shortened) } ?? "Loading…")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Open at login", isOn: $m.atLogin)
                    .toggleStyle(.checkbox).font(.caption)
                Button("Quit") { NSApp.terminate(nil) }.font(.caption)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

@main
struct ClaudeBar: App {
    @StateObject private var m = Model()
    var body: some Scene {
        MenuBarExtra { Panel(m: m) } label: { Text(m.label) }
            .menuBarExtraStyle(.window)
    }
}
