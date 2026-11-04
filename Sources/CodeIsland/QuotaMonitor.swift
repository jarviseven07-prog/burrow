import Foundation
import CodeIslandCore

/// Looks up each agent's weekly quota every quarter hour for the health bars
/// under the pets (design/v24 "D"). Every source asks the agent's own tool
/// or file, with that tool's own login; Burrow never holds a token except
/// the two API keys OpenCode already keeps for the balances (Jarvis agreed
/// 10-31), which go only to their own provider and are never shown.
///
/// Anything missing — a tool not installed, a file not there — leaves that
/// agent without a bar, silently. A lookup that fails (no network yet after
/// the lid opens) keeps the last reading for a while instead
/// (WeeklyQuota.merge) and is tried again a minute later.
@MainActor
final class QuotaMonitor {
    static let interval: TimeInterval = 15 * 60
    /// After a failed lookup, the next try comes this soon.
    static let retryAfterFailure: TimeInterval = 60

    private weak var appState: AppState?
    private var timer: Timer?
    private var retry: Timer?
    /// The round under way: lookups end at their deadlines, but a round
    /// that somehow never reports back must not stop the rest for good
    /// (health check #13), so after `stuckAfter` a new round may start and
    /// the old one's answer is dropped.
    private var round: (id: Int, startedAt: Date)?
    private var rounds = 0
    static let stuckAfter: TimeInterval = 5 * 60
    private var readings: [String: WeeklyQuota.Reading] = [:]

    init(appState: AppState) { self.appState = appState }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// `isRetry`: the one quick try after a failure. It is not tried again
    /// sooner than the quarter hour, so a tool that keeps failing (Codex
    /// logged out) is not started every minute.
    func refresh(isRetry: Bool = false) {
        if let round, Date().timeIntervalSince(round.startedAt) < Self.stuckAfter { return }
        rounds += 1
        let id = rounds
        round = (id, Date())
        retry?.invalidate()
        retry = nil
        let codex = AppState.codexAppServerExecutableURL()
        Task.detached(priority: .utility) {
            async let claude = QuotaSources.claude()
            async let codexLeft = QuotaSources.codex(executable: codex)
            async let antigravity = QuotaSources.antigravity()
            async let openCode = QuotaSources.openCode()
            let lookups: [String: WeeklyQuota.Lookup] = [
                "claude": await claude, "codex": await codexLeft,
                "google-antigravity": await antigravity, "opencode": await openCode,
            ]
            await MainActor.run { [weak self] in self?.finish(lookups, round: id, wasRetry: isRetry) }
        }
    }

    private func finish(_ lookups: [String: WeeklyQuota.Lookup], round id: Int, wasRetry: Bool) {
        guard round?.id == id else { return }
        round = nil
        readings = WeeklyQuota.merge(readings, with: lookups, now: Date())
        appState?.quotaRemaining = readings.mapValues(\.remaining)
        appState?.quotaLabel = readings.compactMapValues(\.label)
        appState?.quotaGroups = readings.compactMapValues { $0.groups.isEmpty ? nil : $0.groups }
        if !wasRetry, lookups.values.contains(.failed) {
            retry = Timer.scheduledTimer(withTimeInterval: Self.retryAfterFailure, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.refresh(isRetry: true) }
            }
        }
    }
}

/// One lookup per agent, each off the main thread: `.absent` when the tool
/// or its data is not there, `.failed` when it did not answer this time.
enum QuotaSources {
    /// Claude Desktop's own record: no file or no number for this week is
    /// no data, never a failure.
    static func claude() async -> WeeklyQuota.Lookup {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        return (try? Data(contentsOf: url)).flatMap { WeeklyQuota.claudeRemaining(historyJSON: $0) }
            .map { .found(.init(remaining: $0)) } ?? .absent
    }

    /// `codex app-server` reads the limits with Codex's own login. A reply
    /// without a weekly window is no bar; no reply is a failure.
    static func codex(executable: URL?) async -> WeeklyQuota.Lookup {
        guard let executable else { return .absent }
        guard let rpc = LineRPC(executable: executable, args: ["-s", "read-only", "-a", "never", "app-server"],
                                timeout: 30) else { return .failed }
        defer { rpc.close() }
        guard rpc.request("initialize", ["clientInfo": ["name": "burrow", "version": "1"]]) != nil else { return .failed }
        rpc.notify("initialized")
        guard let limits = rpc.request("account/rateLimits/read", ["excludeResetCreditDetails": true]) else { return .failed }
        return WeeklyQuota.codexRemaining(rateLimitsResult: limits).map { .found(.init(remaining: $0)) } ?? .absent
    }

    /// Antigravity's ACP server answers `/usage` itself (no model, no quota
    /// spent). It is the copy agent-bridge installs; without it, no bar.
    /// Every group's weekly quota; the pet's bar is Argon's. Always asked in
    /// the same conversation (`usageSession`).
    static func antigravity() async -> WeeklyQuota.Lookup {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".local/share/agent-bridge/antigravity-acp")
        guard let versions = try? fm.contentsOfDirectory(atPath: root.path) else { return .absent }
        let newest = versions.sorted { $0.compare($1, options: .numeric) == .orderedAscending }.last { v in
            fm.isExecutableFile(atPath: root.appendingPathComponent("\(v)/agy_acp_server.par").path)
        }
        guard let newest else { return .absent }
        // An empty folder to start the session in, so it reads no project.
        let cwd = home.appendingPathComponent(".codeisland/acp-cwd")
        try? fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        guard let rpc = LineRPC(executable: root.appendingPathComponent("\(newest)/agy_acp_server.par"),
                                args: [], env: proxyEnvironment(), timeout: 60) else { return .failed }
        defer { rpc.close() }
        let client: [String: Any] = [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
            "clientInfo": ["name": "burrow", "version": "1"],
        ]
        guard rpc.request("initialize", client) != nil else { return .failed }
        let place: [String: Any] = ["cwd": cwd.path, "mcpServers": [Any]()]
        let defaults = UserDefaults.standard
        guard let session = usageSession(
            saved: defaults.string(forKey: antigravitySessionKey),
            resume: { rpc.request("session/resume", place.merging(["sessionId": $0]) { $1 }) != nil },
            create: { rpc.request("session/new", place)?["sessionId"] as? String }
        ) else { return .failed }
        if session.isNew { defaults.set(session.id, forKey: antigravitySessionKey) }
        var text = ""
        _ = rpc.request("session/prompt", ["sessionId": session.id, "prompt": [["type": "text", "text": "/usage"]]]) { note in
            guard let update = (note["params"] as? [String: Any])?["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "agent_message_chunk",
                  let chunk = (update["content"] as? [String: Any])?["text"] as? String else { return }
            text += chunk
        }
        // A reply with no weekly lines ("data not available yet") is a
        // failure too: the last reading stands in a while.
        let groups = WeeklyQuota.antigravityGroups(usageText: text)
        guard let bar = WeeklyQuota.antigravityBar(groups) else { return .failed }
        return .found(.init(remaining: bar, groups: groups))
    }

    /// The one conversation Burrow asks `/usage` in (health check #8: a new
    /// one per lookup left ~0.5 MB on disk every quarter hour, and ACP has
    /// no delete).
    static let antigravitySessionKey = "quotaAntigravitySessionId"

    /// The saved conversation if it can be resumed, else a new one.
    static func usageSession(saved: String?, resume: (String) -> Bool,
                             create: () -> String?) -> (id: String, isNew: Bool)? {
        if let saved, resume(saved) { return (saved, false) }
        return create().map { ($0, true) }
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
    /// A balance that did not come back (no network, a server error) makes
    /// the whole lookup a failure, so the bar never jumps to the other
    /// balance alone.
    static func openCode() async -> WeeklyQuota.Lookup {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/auth.json")
        guard let data = try? Data(contentsOf: url),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .absent }
        let dsKey = (auth["deepseek"] as? [String: Any])?["key"] as? String
        let orKey = (auth["openrouter"] as? [String: Any])?["key"] as? String
        guard dsKey != nil || orKey != nil else { return .absent }
        async let ds = balance("https://api.deepseek.com/user/balance", key: dsKey, parse: WeeklyQuota.deepSeekBalance)
        async let or = balance("https://openrouter.ai/api/v1/credits", key: orKey, parse: WeeklyQuota.openRouterBalance)
        let (d, o) = await (ds, or)
        guard let d, let o else { return .failed }
        guard let remaining = WeeklyQuota.openCodeRemaining(deepSeek: d, openRouter: o) else { return .absent }
        return .found(.init(remaining: remaining, label: WeeklyQuota.balanceLabel(deepSeek: d, openRouter: o)))
    }

    /// The balance; `.some(nil)` when there is none to give (no key, a
    /// refused key, an answer that does not parse); nil when no answer came.
    private static func balance(_ endpoint: String, key: String?, parse: (Data) -> Double?) async -> Double?? {
        guard let key, let url = URL(string: endpoint) else { return .some(nil) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        if status >= 500 { return nil }
        return .some(status == 200 ? parse(data) : nil)
    }
}

/// A child process spoken to in newline-delimited JSON-RPC, one request at a
/// time. Blocking: call it off the main thread.
///
/// Everything ends at the deadline (health check #13): reads wait in
/// `poll` with what is left of it, so neither a child that ignores SIGTERM
/// nor a grandchild still holding the output pipe can hold a read past it;
/// the child gets SIGTERM, and SIGKILL `killGrace` later if it is still up.
final class LineRPC: @unchecked Sendable {
    /// How long a child has to go after SIGTERM before it is killed.
    static let killGrace: TimeInterval = 2

    private let proc = Process()
    private let input: FileHandle
    private let output: FileHandle
    private let deadline: Date
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
        deadline = Date().addingTimeInterval(timeout)
        // A child that died early must not take Burrow down with SIGPIPE.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try proc.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [proc] in Self.stop(proc) }
    }

    var processIdentifier: pid_t { proc.processIdentifier }

    /// The request's result, or nil on an error, a dead child or the deadline.
    /// A success without a result object is an empty one. Notifications that
    /// arrive meanwhile go to `onNotification`.
    func request(_ method: String, _ params: [String: Any],
                 onNotification: ([String: Any]) -> Void = { _ in }) -> [String: Any]? {
        let id = nextId
        nextId += 1
        guard send(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) else { return nil }
        while let message = readMessage() {
            if message["id"] as? Int == id, message["method"] == nil {
                return message["result"] as? [String: Any] ?? (message["error"] == nil ? [:] : nil)
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
        Self.stop(proc)
        try? output.close()
    }

    /// SIGTERM now, SIGKILL in `killGrace` if it is still running.
    private static func stop(_ proc: Process) {
        guard proc.isRunning else { return }
        proc.terminate()
        let pid = proc.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
            if proc.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func send(_ body: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: body) else { return false }
        data.append(0x0A)
        do { try input.write(contentsOf: data) } catch { return false }
        return true
    }

    private func readMessage() -> [String: Any]? {
        let fd = output.fileDescriptor
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { return object }
                continue
            }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let n = poll(&ready, 1, Int32(min(left, 3600) * 1000) + 1)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { if n == 0 { continue } else { return nil } }
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[..<count])
        }
    }
}
