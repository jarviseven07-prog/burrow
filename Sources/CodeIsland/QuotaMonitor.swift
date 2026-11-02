import Foundation
import CodeIslandCore

/// Looks up each agent's weekly quota every quarter hour for the health bars
/// under the pets (design/v24 "D"). Every source asks the agent's own tool
/// or file, with that tool's own login; Burrow never holds a token except
/// the two API keys OpenCode already keeps for the balances (Jarvis agreed
/// 10-31), which go only to their own provider and are never shown.
///
/// Anything missing — a tool not installed, a file not there, no network —
/// leaves that agent without a bar, silently.
@MainActor
final class QuotaMonitor {
    static let interval: TimeInterval = 15 * 60

    private weak var appState: AppState?
    private var timer: Timer?
    private var running = false

    init(appState: AppState) { self.appState = appState }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !running else { return }
        running = true
        let codex = AppState.codexAppServerExecutableURL()
        Task.detached(priority: .utility) {
            async let claude = QuotaSources.claude()
            async let codexLeft = QuotaSources.codex(executable: codex)
            async let antigravity = QuotaSources.antigravity()
            async let openCode = QuotaSources.openCode()
            let balances = await openCode
            let groups = await antigravity
            let found: [String: Double?] = [
                "claude": await claude, "codex": await codexLeft,
                "google-antigravity": groups.map(\.remaining).min(), "opencode": balances.remaining,
            ]
            await MainActor.run { [weak self] in
                self?.running = false
                self?.appState?.quotaRemaining = found.compactMapValues { $0 }
                self?.appState?.quotaLabel = balances.label.map { ["opencode": $0] } ?? [:]
                self?.appState?.quotaGroups = groups.isEmpty ? [:] : ["google-antigravity": groups]
            }
        }
    }
}

/// One lookup per agent. Each runs off the main thread and returns nil on
/// any trouble.
enum QuotaSources {
    static func claude() async -> Double? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        return (try? Data(contentsOf: url)).flatMap { WeeklyQuota.claudeRemaining(historyJSON: $0) }
    }

    /// `codex app-server` reads the limits with Codex's own login.
    static func codex(executable: URL?) async -> Double? {
        guard let executable,
              let rpc = LineRPC(executable: executable, args: ["-s", "read-only", "-a", "never", "app-server"],
                                timeout: 30) else { return nil }
        defer { rpc.close() }
        guard rpc.request("initialize", ["clientInfo": ["name": "burrow", "version": "1"]]) != nil else { return nil }
        rpc.notify("initialized")
        return rpc.request("account/rateLimits/read", ["excludeResetCreditDetails": true])
            .flatMap { WeeklyQuota.codexRemaining(rateLimitsResult: $0) }
    }

    /// Antigravity's ACP server answers `/usage` itself (no model, no quota
    /// spent). It is the copy agent-bridge installs; without it, no bar.
    /// Every group's weekly quota; the pet's bar is the tightest.
    static func antigravity() async -> [WeeklyQuota.Group] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".local/share/agent-bridge/antigravity-acp")
        guard let versions = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        let newest = versions.sorted { $0.compare($1, options: .numeric) == .orderedAscending }.last { v in
            fm.isExecutableFile(atPath: root.appendingPathComponent("\(v)/agy_acp_server.par").path)
        }
        guard let newest else { return [] }
        // An empty folder to start the session in, so it reads no project.
        let cwd = home.appendingPathComponent(".codeisland/acp-cwd")
        try? fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        guard let rpc = LineRPC(executable: root.appendingPathComponent("\(newest)/agy_acp_server.par"),
                                args: [], env: proxyEnvironment(), timeout: 60) else { return [] }
        defer { rpc.close() }
        let client: [String: Any] = [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
            "clientInfo": ["name": "burrow", "version": "1"],
        ]
        guard rpc.request("initialize", client) != nil,
              let session = rpc.request("session/new", ["cwd": cwd.path, "mcpServers": [Any]()])?["sessionId"] as? String
        else { return [] }
        var text = ""
        _ = rpc.request("session/prompt", ["sessionId": session, "prompt": [["type": "text", "text": "/usage"]]]) { note in
            guard let update = (note["params"] as? [String: Any])?["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "agent_message_chunk",
                  let chunk = (update["content"] as? [String: Any])?["text"] as? String else { return }
            text += chunk
        }
        return WeeklyQuota.antigravityGroups(usageText: text)
    }

    /// The system proxy, which the ACP server (unlike URLSession) does not
    /// pick up by itself.
    private static func proxyEnvironment() -> [String: String] {
        guard let s = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return [:] }
        var env: [String: String] = [:]
        if s["HTTPSEnable"] as? Int == 1, let h = s["HTTPSProxy"] as? String, let p = s["HTTPSPort"] as? Int {
            env["HTTPS_PROXY"] = "http://\(h):\(p)"
        }
        if s["HTTPEnable"] as? Int == 1, let h = s["HTTPProxy"] as? String, let p = s["HTTPPort"] as? Int {
            env["HTTP_PROXY"] = "http://\(h):\(p)"
        }
        if !env.isEmpty { env["NO_PROXY"] = "localhost,127.0.0.1,::1,.local" }
        return env
    }

    /// OpenCode's two balances, with the keys OpenCode keeps: the bar's
    /// percentage and the amounts for the den.
    static func openCode() async -> (remaining: Double?, label: String?) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/auth.json")
        guard let data = try? Data(contentsOf: url),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        let dsKey = (auth["deepseek"] as? [String: Any])?["key"] as? String
        let orKey = (auth["openrouter"] as? [String: Any])?["key"] as? String
        async let ds = balance("https://api.deepseek.com/user/balance", key: dsKey, parse: WeeklyQuota.deepSeekBalance)
        async let or = balance("https://openrouter.ai/api/v1/credits", key: orKey, parse: WeeklyQuota.openRouterBalance)
        let (d, o) = await (ds, or)
        return (WeeklyQuota.openCodeRemaining(deepSeek: d, openRouter: o),
                WeeklyQuota.balanceLabel(deepSeek: d, openRouter: o))
    }

    private static func balance(_ endpoint: String, key: String?, parse: (Data) -> Double?) async -> Double? {
        guard let key, let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }
}

/// A child process spoken to in newline-delimited JSON-RPC, one request at a
/// time, killed at its deadline. Blocking: call it off the main thread.
final class LineRPC: @unchecked Sendable {
    private let proc = Process()
    private let input: FileHandle
    private let output: FileHandle
    private var buffer = Data()
    private var nextId = 1

    init?(executable: URL, args: [String], env: [String: String] = [:], timeout: TimeInterval) {
        let stdin = Pipe(), stdout = Pipe()
        proc.executableURL = executable
        proc.arguments = args
        var environment = ProcessInfo.processInfo.environment
        env.forEach { environment[$0] = $1 }
        proc.environment = environment
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        // A child that died early must not take Burrow down with SIGPIPE.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try proc.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [proc] in
            if proc.isRunning { proc.terminate() }
        }
    }

    /// The request's result, or nil on an error, a dead child or the deadline.
    /// Notifications that arrive meanwhile go to `onNotification`.
    func request(_ method: String, _ params: [String: Any],
                 onNotification: ([String: Any]) -> Void = { _ in }) -> [String: Any]? {
        let id = nextId
        nextId += 1
        guard send(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) else { return nil }
        while let message = readMessage() {
            if message["id"] as? Int == id, message["method"] == nil {
                return message["result"] as? [String: Any]
            }
            if message["id"] == nil { onNotification(message) }
        }
        return nil
    }

    func notify(_ method: String) {
        _ = send(["jsonrpc": "2.0", "method": method])
    }

    func close() {
        try? input.close()
        if proc.isRunning { proc.terminate() }
    }

    private func send(_ body: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: body) else { return false }
        data.append(0x0A)
        do { try input.write(contentsOf: data) } catch { return false }
        return true
    }

    private func readMessage() -> [String: Any]? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { return object }
                continue
            }
            let chunk = output.availableData
            guard !chunk.isEmpty else { return nil }
            buffer.append(chunk)
        }
    }
}
