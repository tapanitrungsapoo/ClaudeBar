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
struct Profile: Decodable { struct Org: Decodable { let uuid: String }; let organization: Org }
struct Creds: Decodable { let accessToken: String; let subscriptionType: String? }
struct Msg: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

// Keychain entry of the default Claude Code login. A login made with CLAUDE_CONFIG_DIR set is stored
// under this name plus "-" and the first 8 hex digits of sha256(config dir).
let baseService = "Claude Code-credentials"

// Going through /usr/bin/security avoids a Keychain prompt.
func security(_ args: [String]) -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? data : nil
}

// Every Claude Code login on this Mac, default one first. dump-keychain lists names only, no secrets.
func credentialServices() -> [String] {
    let text = security(["dump-keychain"]).map { String(decoding: $0, as: UTF8.self) } ?? ""
    let names = text.split(separator: "\n").compactMap { line -> String? in
        guard let r = line.range(of: #""svce"<blob>=""#) else { return nil }
        let name = String(line[r.upperBound...].dropLast())
        return name.range(of: #"^Claude Code-credentials(-[0-9a-f]{8})?$"#, options: .regularExpression) != nil ? name : nil
    }
    return Set(names).sorted()   // baseService is a prefix of the others, so it sorts first
}

func readCredentials(service: String) throws -> Creds {
    guard let data = security(["find-generic-password", "-s", service, "-w"]) else { throw Msg("No Claude Code login found") }
    struct Wrap: Decodable { let claudeAiOauth: Creds }
    return try JSONDecoder().decode(Wrap.self, from: data).claudeAiOauth
}

func api<T: Decodable>(_ path: String, token: String) async throws -> T {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/" + path)!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw Msg(code == 401 ? "Token expired – run Claude Code once" : "HTTP \(code)") }
    return try JSONDecoder().decode(T.self, from: data)
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

// Seconds until the next refresh: every 5 minutes, or just after the nearest reset if that comes sooner.
// The 10 s floor keeps a reset that lands right after a refresh from causing back-to-back calls (HTTP 429).
func nextRefresh(_ resets: [String?], now: Date = Date(), every: Double = 300) -> Double {
    let soonest = resets.compactMap { parseDate($0)?.timeIntervalSince(now) }.filter { $0 > 0 }.min()
    return max(10, min(every, (soonest ?? every) + 5))
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

// Claude Code writes transcripts to <config dir>/projects: ~/.claude, or the folder in CLAUDE_CONFIG_DIR.
// ponytail: only finds config folders named ~/.claude*; a CLAUDE_CONFIG_DIR somewhere else is not read.
func transcriptRoots() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
    return names.filter { $0.hasPrefix(".claude") }.sorted()
        .map { home.appendingPathComponent($0).appendingPathComponent("projects") }
        .filter { var dir: ObjCBool = false; return FileManager.default.fileExists(atPath: $0.path, isDirectory: &dir) && dir.boolValue }
}

// Reads <config dir>/projects/**/*.jsonl. Only sees Claude Code on this Mac (not claude.ai chat or other machines).
final class Transcripts: @unchecked Sendable {
    private let lock = NSLock()
    // Parsed files keyed by path; a file is re-read only when its mtime changes.
    private var cache: [String: (mtime: Date, cwd: String?, owner: String?, entries: [String: Entry])] = [:]
    private static let needle = Data(#""type":"assistant""#.utf8)
    private static let ownerNeedle = Data(#""session-owner""#.utf8)

    private static func num(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }

    // owner = organization of the logged-in account, from the session's "session-owner" lines.
    // ponytail: one owner per file (the last one); a /login to another account mid-session is not split.
    static func parse(_ url: URL) -> (cwd: String?, owner: String?, entries: [String: Entry]) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return (nil, nil, [:]) }
        var cwd: String?, owner: String?
        var out: [String: Entry] = [:]
        for line in data.split(separator: 0x0A)
        where line.range(of: needle) != nil || line.range(of: ownerNeedle) != nil {
            guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if d["type"] as? String == "session-owner" { owner = (d["organizationUuid"] as? String) ?? owner; continue }
            guard d["type"] as? String == "assistant",
                  let ts = d["timestamp"] as? String,
                  let m = d["message"] as? [String: Any],
                  let model = m["model"] as? String, model.hasPrefix("claude"),
                  let u = m["usage"] as? [String: Any],
                  // Only Claude subscription requests count toward a plan limit. Anthropic request IDs start
                  // with "req_"; Bedrock lines carry a UUID and an arn:aws:bedrock model.
                  (d["requestId"] as? String)?.hasPrefix("req_") == true else { continue }
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
        return (cwd, owner, out)
    }

    // Usage since `start` by the account whose organization uuid is `org`.
    func breakdown(since start: Date, org: String, calibrate: (name: String, share: Double)? = nil, roots: [URL] = transcriptRoots()) -> Breakdown {
        lock.lock(); defer { lock.unlock() }
        var files: [(url: URL, root: URL, mtime: Date)] = []
        for root in roots {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let u as URL in en where u.pathExtension == "jsonl" {
                if let mt = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, mt >= start {
                    files.append((u, root, mt))
                }
            }
        }
        // Session files before their subagent files, so subagents can take the session's owner and project name.
        files.sort { $0.url.pathComponents.count < $1.url.pathComponents.count }
        let live = Set(files.map { $0.url.path })
        cache = cache.filter { live.contains($0.key) }

        // Timestamps are all UTC ISO-8601, so the first 19 chars compare correctly as strings.
        let startStr = ISO8601DateFormatter().string(from: start).prefix(19)
        var names: [String: String] = [:], owners: [String: String] = [:]
        var merged: [String: (entry: Entry, proj: String)] = [:]
        for f in files {
            let key = f.url.path
            if cache[key]?.mtime != f.mtime {
                let p = Self.parse(f.url)
                cache[key] = (f.mtime, p.cwd, p.owner, p.entries)
            }
            guard let c = cache[key] else { continue }
            // Subagent transcripts (<project>/<session>/subagents/*.jsonl) have no owner line: use the session's.
            var owner = c.owner
            var dir = f.url.deletingLastPathComponent()
            while owner == nil, dir.path.count > f.root.path.count {
                owner = owners[dir.path + ".jsonl"]
                dir = dir.deletingLastPathComponent()
            }
            owners[key] = owner
            guard owner == org else { continue }
            let proj = f.root.appendingPathComponent(String(key.dropFirst(f.root.path.count + 1).split(separator: "/").first ?? "?")).path
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
            byProj[names[v.proj] ?? (v.proj as NSString).lastPathComponent, default: 0] += cost
        }
        return Breakdown(models: top(byModel), projects: top(byProj))
    }
}

// MARK: - Model

// One column per organization. Two config folders can hold the same account (for example ~/.claude and
// ~/.claude-personal); keep the first one, unless only a later one loaded without an error.
func dedupe(_ list: [Account]) -> [Account] {
    var out: [Account] = []
    for a in list {
        guard let o = a.org, let i = out.firstIndex(where: { $0.org == o }) else { out.append(a); continue }
        if out[i].error != nil, a.error == nil { out[i] = a }
    }
    return out
}

struct Account: Identifiable {
    let service: String
    var id: String { service }
    var plan = ""
    var org: String?
    var usage: Usage?
    var error: String?
    var todayWeekly: Double?
    var breakdown = Breakdown()
}

@MainActor
final class Model: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var error: String?
    @Published var updated: Date?
    private let transcripts = Transcripts()
    private var orgs: [String: String] = [:]   // access token -> organization uuid
    // Plain @Published (not @State): the Command Line Tools SDK ships without the SwiftUI macro plugin.
    @Published var atLogin = SMAppService.mainApp.status == .enabled {
        didSet { try? atLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }

    init() {
        Task {
            while true {
                await refresh()
                let resets = accounts.flatMap { a in
                    [a.usage?.five_hour?.resets_at, a.usage?.seven_day?.resets_at, a.usage?.weekly(model: "Fable")?.resets_at]
                }
                try? await Task.sleep(for: .seconds(nextRefresh(resets)))
            }
        }
    }

    // Menu bar shows the default login (~/.claude); the other accounts are in the popup.
    var label: String {
        func pct(_ w: Window?) -> String { w.map { "\(Int($0.utilization.rounded()))%" } ?? "–" }
        let u = accounts.first?.usage
        return "✱ \(pct(u?.five_hour)) · W \(pct(u?.seven_day))"
    }

    func refresh() async {
        let services = credentialServices()
        error = services.isEmpty ? "No Claude Code login found" : nil
        var out: [Account] = []
        for s in services { out.append(await load(s)) }
        accounts = dedupe(out)
        if out.contains(where: { $0.error == nil }) { updated = Date() }
    }

    private func load(_ service: String) async -> Account {
        // Start from the last good data, so a failed refresh keeps the old numbers on screen.
        var a = accounts.first { $0.service == service } ?? Account(service: service)
        a.error = nil
        var org: String?
        do {
            let creds = try readCredentials(service: service)
            a.plan = creds.subscriptionType?.capitalized ?? ""
            let usage: Usage = try await api("usage", token: creds.accessToken)
            a.usage = usage
            if let w = usage.seven_day?.utilization {
                // Saved in UserDefaults so an app restart doesn't reset today's count. The default login
                // keeps the old keys "day"/"base"; others add their Keychain suffix.
                let k = String(service.dropFirst(baseService.count))
                let d = UserDefaults.standard
                let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
                let base = todayBase(current: w, savedDay: d.double(forKey: "day" + k), savedBase: d.double(forKey: "base" + k), today: today)
                d.set(today, forKey: "day" + k); d.set(base, forKey: "base" + k)
                a.todayWeekly = w - base
            }
            // The organization tells this account's transcripts apart from the other account's. Asked once per token.
            if orgs[creds.accessToken] == nil, let p: Profile = try? await api("profile", token: creds.accessToken) {
                orgs[creds.accessToken] = p.organization.uuid
            }
            org = orgs[creds.accessToken]
            a.org = org
        } catch {
            a.error = "\(error)"
        }
        // Same 7-day window as the weekly limit. Runs off the main thread: transcripts can be hundreds of MB.
        if let org {
            let start = (parseDate(a.usage?.seven_day?.resets_at) ?? Date()).addingTimeInterval(-7 * 86400)
            let t = transcripts
            let cal = a.usage?.scopedShare()
            a.breakdown = await Task.detached { t.breakdown(since: start, org: org, calibrate: cal) }.value
        }
        return a
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
            // Hand-drawn bar: ProgressView ignores .tint in a menu bar window and always draws the accent color.
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(u >= 90 ? Color.red : u >= 70 ? .orange : .blue)
                        .frame(width: g.size.width * min(max(u / 100, 0), 1))
                }
            }
            .frame(height: 6)
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

struct AccountView: View {
    let a: Account
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(a.plan.isEmpty ? "Claude" : "Claude · \(a.plan)").font(.headline)
            if let e = a.error { Text(e).font(.caption).foregroundStyle(.red) }
            Row(title: "5-hour session", w: a.usage?.five_hour)
            Row(title: "Weekly", w: a.usage?.seven_day, extra: a.todayWeekly.map { "Today +\(Int($0.rounded()))%" })
            if let f = a.usage?.weekly(model: "Fable") { Row(title: "Weekly · Fable", w: f) }
            if !a.breakdown.models.isEmpty, let w = a.usage?.seven_day?.utilization {
                Divider()
                let used = "Weekly \(Int(w.rounded()))% by"
                Shares(title: "\(used) model · est.", items: a.breakdown.models, weekly: w)
                Shares(title: "\(used) project · est.", items: a.breakdown.projects, weekly: w)
            }
        }
        .frame(width: 272, alignment: .topLeading)
    }
}

struct Panel: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let e = m.error { Text(e).font(.caption).foregroundStyle(.red) }
            // One column per account, side by side, so two accounts don't make the popup taller than the screen.
            HStack(alignment: .top, spacing: 14) {
                ForEach(m.accounts) { a in
                    if a.id != m.accounts.first?.id { Divider() }
                    AccountView(a: a)
                }
            }
            Divider()
            HStack {
                Text(m.updated.map { "Updated " + $0.formatted(date: .omitted, time: .shortened) } ?? "Loading…")
                    .font(.caption).foregroundStyle(.secondary)
                Button { Task { await m.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                Spacer()
                Toggle("Open at login", isOn: $m.atLogin)
                    .toggleStyle(.checkbox).font(.caption)
                Button("Quit") { NSApp.terminate(nil) }.font(.caption)
            }
        }
        .padding(14)
        // Ideal size, not a minimum: with a flexible width the menu bar window stays at its smallest
        // width and clips the account columns.
        .fixedSize()
    }
}

@main
struct ClaudeBar: App {
    @StateObject private var m = Model()

    init() {
        // One copy only. The login item and macOS "reopen at login" can each start a copy (build.sh leaves
        // one in the project folder and one in ~/Applications), and each copy adds its own menu bar item.
        // ponytail: the older process (lower pid) wins; pid wraparound is ignored.
        let me = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier < me }) { exit(0) }
    }
    var body: some Scene {
        MenuBarExtra { Panel(m: m) } label: { Text(m.label) }
            .menuBarExtraStyle(.window)
    }
}
