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
    let five_hour: Window?; let seven_day: Window?; let limits: [Limit]?
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

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    @Published var usage: Usage?
    @Published var plan = ""
    @Published var error: String?
    @Published var updated: Date?
    // Plain @Published (not @State): the Command Line Tools SDK ships without the SwiftUI macro plugin.
    @Published var atLogin = SMAppService.mainApp.status == .enabled {
        didSet { try? atLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }

    init() {
        Task { while true { await refresh(); try? await Task.sleep(for: .seconds(60)) } }
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
            updated = Date()
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }
}

// MARK: - UI

struct Row: View {
    let title: String
    let w: Window?
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
            Text(resetText(w?.resets_at)).font(.caption).foregroundStyle(.secondary)
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
            Row(title: "Weekly", w: m.usage?.seven_day)
            if let f = m.usage?.weekly(model: "Fable") { Row(title: "Weekly · Fable", w: f) }
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
