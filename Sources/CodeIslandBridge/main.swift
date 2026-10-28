// ============================================================
// codeisland-bridge — Native Claude Code hook event forwarder
// ============================================================
// Replaces shell script + nc with:
// • Proper JSON parsing (no string manipulation)
// • Terminal environment detection (TERM_PROGRAM, bundle id, TTY)
// • Native POSIX socket communication
// • session_id validation (drop events without it)
// • CODEISLAND_SKIP env var support
// • Debug logging (CODEISLAND_DEBUG)
// ============================================================

import Foundation
import Darwin
import CodeIslandCore

// MARK: - Global Safety Net

// Never let a broken pipe kill the bridge — just fail the write silently
signal(SIGPIPE, SIG_IGN)

// Hard deadline: if anything hangs beyond this, bail out cleanly.
// Non-blocking events get 8s; blocking (permission/question) gets no alarm
// since those legitimately wait for user interaction.
// The alarm is armed later once we know the event type.
signal(SIGALRM) { _ in
    _exit(0)  // immediate, no cleanup — we're stuck anyway
}

// MARK: - Helper Functions

func detectTTY() -> String {
    let fd = open("/dev/tty", O_RDONLY | O_NOCTTY)
    if fd >= 0 {
        if let name = ttyname(fd) {
            close(fd)
            return String(cString: name)
        }
        close(fd)
    }
    return ""
}

func findBinary(_ name: String) -> String? {
    let searchPaths = [
        "/opt/homebrew/bin/\(name)",
        "/usr/local/bin/\(name)",
        "/usr/bin/\(name)",
    ]
    return searchPaths.first { access($0, X_OK) == 0 }
}

func runCommand(_ path: String, args: [String]) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (str?.isEmpty == false) ? str : nil
    } catch {
        return nil
    }
}

func executablePath(for pid: pid_t) -> String? {
    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
    guard len > 0 else { return nil }
    return String(cString: pathBuffer)
}

func parentPID(of pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    guard ret > 0, info.pbi_ppid > 0 else { return nil }
    return pid_t(info.pbi_ppid)
}

func buildAncestry(startingAt pid: pid_t, maxDepth: Int = 6) -> [(pid: pid_t, executablePath: String?)] {
    guard pid > 0 else { return [] }
    var result: [(pid: pid_t, executablePath: String?)] = []
    var current: pid_t? = pid
    var visited = Set<pid_t>()

    while let currentPid = current, currentPid > 0, result.count < maxDepth, !visited.contains(currentPid) {
        visited.insert(currentPid)
        result.append((pid: currentPid, executablePath: executablePath(for: currentPid)))
        current = parentPID(of: currentPid)
    }

    return result
}

func processArguments(for pid: pid_t) -> [String] {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
    return ProcArgsParser.parse(Array(buffer.prefix(size)))?.arguments ?? []
}

func bundleIdentifier(forExecutable path: String) -> String? {
    guard let appPath = ProcessAncestry.outermostAppBundlePath(forExecutable: path) else { return nil }
    return Bundle(path: appPath)?.bundleIdentifier
}

func debugLog(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(message)\n"
    // CODEISLAND_BRIDGE_LOG moves the log: the tests that run this binary point
    // it at a temp file, so their payloads stay out of the log real hooks append to.
    let path = ProcessInfo.processInfo.environment["CODEISLAND_BRIDGE_LOG"] ?? "/tmp/codeisland-bridge.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
}

func nonEmptyString(_ value: Any?) -> String? {
    guard let raw = value as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func connectSocket(_ path: String, timeoutMs: Int32 = 3000) -> Int32? {
    let sock = socket(AF_UNIX, SOCK_STREAM, 0)
    guard sock >= 0 else { return nil }

    // Suppress per-write SIGPIPE on this socket (belt-and-suspenders with global SIG_IGN)
    var on: Int32 = 1
    setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
        path.withCString { _ = strcpy(ptr, $0) }
    }

    // Non-blocking connect with 3s timeout — prevents hanging if the listener is stuck
    let origFlags = fcntl(sock, F_GETFL)
    _ = fcntl(sock, F_SETFL, origFlags | O_NONBLOCK)

    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    if result != 0 && errno != EINPROGRESS {
        close(sock)
        return nil
    }

    if result != 0 {
        // Wait for connect to complete (or timeout)
        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, timeoutMs)
        if ready <= 0 {
            close(sock)
            return nil
        }
        // Check for socket error
        var sockErr: Int32 = 0
        var errLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &sockErr, &errLen)
        if sockErr != 0 {
            close(sock)
            return nil
        }
    }

    // Restore blocking mode for send/recv
    _ = fcntl(sock, F_SETFL, origFlags)
    return sock
}

func sendAll(_ sock: Int32, data: Data) {
    data.withUnsafeBytes { buf in
        guard let base = buf.baseAddress else { return }
        var sent = 0
        while sent < buf.count {
            let n = send(sock, base + sent, buf.count - sent, 0)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            sent += n
        }
    }
}

func recvAll(_ sock: Int32) -> Data {
    var response = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = recv(sock, &buf, buf.count, 0)
        if n < 0 {
            if errno == EINTR { continue }
            break
        }
        if n == 0 { break }
        response.append(contentsOf: buf[..<n])
    }
    return response
}

// MARK: - Main

let socketPath = SocketPath.path
let env = ProcessInfo.processInfo.environment
let args = CommandLine.arguments

// Parse --source flag (e.g. --source codex)
var sourceTag: String? = nil
if let idx = args.firstIndex(of: "--source"), idx + 1 < args.count {
    sourceTag = args[idx + 1]
}

// Parse --event flag (e.g. --event sessionStart) for CLIs that lack hook_event_name in stdin
var eventTag: String? = nil
if let idx = args.firstIndex(of: "--event"), idx + 1 < args.count {
    eventTag = args[idx + 1]
}

// Google Antigravity refuses the tool call when its PreToolUse hook prints no
// decision, so answer before any of the early exits below can leave stdout
// empty (island not running, CODEISLAND_SKIP, a deadline). The island only
// observes Antigravity tool calls; the decision stays with Antigravity (#339).
var wroteAntigravityDecision = false
func writeAntigravityDecisionIfNeeded(eventName: String?) {
    guard !wroteAntigravityDecision,
          let stdout = AntigravityHookContract.hookStdout(source: sourceTag, eventName: eventName) else { return }
    wroteAntigravityDecision = true
    FileHandle.standardOutput.write(Data(stdout.utf8))
}
writeAntigravityDecisionIfNeeded(eventName: eventTag)

// Quick exit: skip if CODEISLAND_SKIP is set
guard env["CODEISLAND_SKIP"] == nil else { exit(0) }

// Quick exit: a hook for an agent Burrow does not track. Older installs left
// hooks in other agents' configs (e.g. `--source gemini` in
// ~/.gemini/settings.json); their events are not ours to show.
if let sourceTag, SessionSnapshot.normalizedSupportedSource(sourceTag) == nil { exit(0) }

// Quick exit: socket doesn't exist or isn't a socket
var statBuf = stat()
guard stat(socketPath, &statBuf) == 0, (statBuf.st_mode & S_IFMT) == S_IFSOCK else { exit(0) }

// Safety: arm a short alarm before reading stdin — if the calling process
// forgot to close its pipe, we bail out instead of blocking forever.
alarm(5)
let input = FileHandle.standardInput.readDataToEndOfFile()
alarm(0)  // stdin done, cancel preliminary alarm
let parsedInput = try? JSONSerialization.jsonObject(with: input) as? [String: Any]
if let inputStr = String(data: input, encoding: .utf8) {
    debugLog("raw input: \(inputStr)")
}

guard !input.isEmpty, var json = parsedInput else {
    exit(0)
}

// Generic compatibility: accept common camelCase aliases from third-party forks
if json["hook_event_name"] == nil {
    if let event = nonEmptyString(json["hookEventName"]) {
        json["hook_event_name"] = event
    } else if let event = nonEmptyString(json["eventName"]) {
        json["hook_event_name"] = event
    } else if let event = nonEmptyString(json["event"]) {
        json["hook_event_name"] = event
    } else if let event = eventTag {
        json["hook_event_name"] = event
    }
}
if json["session_id"] == nil {
    if let sessionId = nonEmptyString(json["sessionId"]) {
        json["session_id"] = sessionId
    } else if let payload = json["payload"] as? [String: Any],
              let sessionId = nonEmptyString(payload["session_id"]) ?? nonEmptyString(payload["sessionId"]) {
        json["session_id"] = sessionId
    } else if let data = json["data"] as? [String: Any],
              let sessionId = nonEmptyString(data["session_id"]) ?? nonEmptyString(data["sessionId"]) {
        json["session_id"] = sessionId
    } else if let conversationId = nonEmptyString(json["conversationId"]) {
        // Google Antigravity (Gemini-based) stdin carries no session_id; it uses
        // `conversationId` as the stable per-conversation key (#215).
        json["session_id"] = conversationId
    }
}

// Google Antigravity sends the transcript path as camelCase `transcriptPath`;
// the rest of CodeIsland reads snake_case `transcript_path` (used by the JSONL
// tailer + cwd inference). Bridge the alias when only the camelCase form exists.
if json["transcript_path"] == nil, let tp = nonEmptyString(json["transcriptPath"]) {
    json["transcript_path"] = tp
}

// Resolve process ancestry once — used for both session_id fallback (#148) and
// _ppid resolution downstream. Some CLIs execute hooks through `sh -c`, so
// `getppid()` is a transient shell rather than the long-lived CLI process.
let immediateParentPID = getppid()
let ancestry = buildAncestry(startingAt: immediateParentPID)
let coreAncestry = ancestry.map { (pid: Int32($0.pid), executablePath: $0.executablePath) }

// Source tag (e.g. "codex" when called via --source codex). If the caller did not pass
// one (e.g. the omo OpenCode plugin triggering Claude hooks without --source), infer
// the real source from the process ancestry so we don't misattribute the event to
// whichever hook path fired it. See issue #95.
// Events that arrived via a plugin proxy (no declared source but ancestry
// inferred a real source — e.g. the omo OpenCode plugin firing Claude hooks)
// are marked `_via_plugin` so the host app can route them per
// pluginSessionMode (#123). A direct plugin's own `_source` counts as declared,
// and Claude Code firing its own (source-less) hook is not a proxy.
let bridgeSource = CLIProcessResolver.bridgeSource(
    sourceTag: sourceTag,
    payloadSource: json["_source"] as? String,
    ancestry: coreAncestry
)
let effectiveSource = bridgeSource.source
if let source = effectiveSource {
    json["_source"] = source
}
if bridgeSource.viaPlugin {
    json["_via_plugin"] = true
}

let resolvedTrackedPID = CLIProcessResolver.resolvedTrackedPID(
    immediateParentPID: Int32(immediateParentPID),
    source: effectiveSource,
    ancestry: coreAncestry
)
json["_ppid"] = resolvedTrackedPID
if resolvedTrackedPID != immediateParentPID {
    json["_hook_ppid"] = Int32(immediateParentPID)
}
// Callers that know their process is not the agent's lifetime opt out. OpenCode 2
// runs plugins in a shared background service that outlives the client that
// spawned it: tracked as the CLI, it would be SIGTERMed as a "reparented orphan"
// the moment that first client quits, taking every session with it (#332).
if json["_untracked_process"] as? Bool == true {
    json["_ppid"] = 0
    json.removeValue(forKey: "_hook_ppid")
}

// Validate: must have non-empty session_id
if json["session_id"] == nil,
   let source = sourceTag,
   !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    // Fallback for third-party providers that don't include a stable session ID.
    // Use the root same-source binary in the ancestry so sub-agent processes
    // (#148) collapse onto a single session card instead of fanning into N cards
    // (one per sub-agent ppid).
    let sessionPID = CLIProcessResolver.resolvedSessionPID(
        immediateParentPID: Int32(immediateParentPID),
        source: effectiveSource ?? source,
        ancestry: coreAncestry
    )
    json["session_id"] = "\(source)-ppid-\(sessionPID)"
    debugLog("session_id missing, generated fallback id: \(json["session_id"] ?? "")")
}
guard let sessionId = json["session_id"] as? String, !sessionId.isEmpty else {
    debugLog("no session_id, dropping")
    exit(0)
}

// Event type detection
let eventName = json["hook_event_name"] as? String ?? ""
let normalizedEventName = EventNormalizer.normalize(eventName)
// agy names the event on stdin, not in --event.
writeAntigravityDecisionIfNeeded(eventName: eventName)
let isGeminiBasedSource = sourceTag == "google-antigravity" || effectiveSource == "google-antigravity"
// Antigravity's PreToolUse is NOT a blocking approval: it was already answered
// above, and holding it for an island card only stacked a second prompt in
// front of Antigravity's own (#339).
let isPermission = normalizedEventName == "PermissionRequest"
let isQuestion = normalizedEventName == "Notification" && json["question"] as? String != nil
let isBlocking = isPermission || isQuestion

debugLog("event=\(eventName) normalized=\(normalizedEventName) session=\(sessionId) permission=\(isPermission) question=\(isQuestion)")

// Arm deadline for env collection + connect + send (protects all events).
// For blocking events, this is disarmed right before the long recvAll wait.
alarm(isBlocking ? 8 : 4)

// --- Deep terminal environment collection ---
// Terminal app identification (only include when present)
if let termApp = env["TERM_PROGRAM"], !termApp.isEmpty {
    json["_term_app"] = termApp
}
if let termBundle = env["__CFBundleIdentifier"], !termBundle.isEmpty {
    json["_term_bundle"] = termBundle
}
// ChatGPT starts Codex Desktop's app-server without __CFBundleIdentifier.
// Without a bundle its hooks were keyed as a CLI thread, a second card next
// to the `codexapp:` one discovery makes for the same Desktop thread.
if nonEmptyString(json["_term_bundle"]) == nil, effectiveSource == "codex" {
    let ancestors = ancestry.map {
        ProcessAncestor(
            pid: Int32($0.pid),
            executablePath: $0.executablePath,
            arguments: processArguments(for: $0.pid),
            bundleIdentifier: $0.executablePath.flatMap(bundleIdentifier(forExecutable:))
        )
    }
    if let desktopBundle = CLIProcessResolver.codexDesktopTermBundle(ancestry: ancestors) {
        json["_term_bundle"] = desktopBundle
    }
}

// TTY path
let tty = detectTTY()
if !tty.isEmpty {
    json["_tty"] = tty
}


// Claude Desktop Code tab: Claude Desktop's own id for this session. The hook's
// session_id is the CLI's id, which Claude Desktop's `claude://code/continue`
// link does not accept; this one opens that exact session on click.
if let host = env["CLAUDE_CODE_HOST_SESSION_ID"], !host.isEmpty {
    json["_claude_desktop_session"] = host
}

// Inject cwd if not already present. Google Antigravity hooks do not
// include a `cwd` field, so CodeIsland cannot resolve the project name and falls back
// to "Session". Populating it here lets the approval card show the actual folder name.
if json["cwd"] == nil {
    json["cwd"] = FileManager.default.currentDirectoryPath
}

// --- Serialize enriched JSON ---
guard let enriched = try? JSONSerialization.data(withJSONObject: json) else { exit(0) }

// --- Connect to Unix socket ---
if isGeminiBasedSource && isPermission {
    // Delay slightly to give the terminal TTY time to display the prompt
    // before showing the notch approval card.
    usleep(250_000)
}
let connectTimeoutMs: Int32 = isBlocking ? 3000 : 1000
guard let sock = connectSocket(socketPath, timeoutMs: connectTimeoutMs) else {
    debugLog("socket connect failed")
    exit(0)
}

// Set socket timeouts
var sendTv = timeval(tv_sec: isBlocking ? 86400 : 1, tv_usec: 0)
setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &sendTv, socklen_t(MemoryLayout<timeval>.size))
// Recv timeout: server responds within ms, but allow headroom for main-thread scheduling
var recvTv = timeval(tv_sec: isBlocking ? 86400 : 1, tv_usec: 0)
setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &recvTv, socklen_t(MemoryLayout<timeval>.size))

// Send enriched event data
sendAll(sock, data: enriched)

// Signal end of write (half-close → server sees EOF)
shutdown(sock, SHUT_WR)

// Blocking events wait for user interaction (minutes/hours) — disarm the deadline.
// Non-blocking events keep the alarm; SO_RCVTIMEO (3s) + alarm(8) double-protect.
if isBlocking {
    alarm(0)
}

// Wait for server response — critical: without this, close() races ahead
// of NWListener's main-thread handler and the event is lost
let response = recvAll(sock)

// Blocking events: forward response to stdout
if isBlocking && !response.isEmpty {
    if isGeminiBasedSource {
        if let jsonObj = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
           let hookOutput = jsonObj["hookSpecificOutput"] as? [String: Any],
           let decisionObj = hookOutput["decision"] as? [String: Any],
           let behavior = decisionObj["behavior"] as? String {
            let translatedBehavior = (behavior == "allow" || behavior == "always") ? "allow" : "deny"
            let responseDict = ["decision": translatedBehavior]
            if let responseData = try? JSONSerialization.data(withJSONObject: responseDict) {
                FileHandle.standardOutput.write(responseData)
            } else {
                FileHandle.standardOutput.write(response)
            }
        } else {
            // Fallback: search for "allow" or "deny" in raw string to be resilient
            let responseStr = String(data: response, encoding: .utf8) ?? ""
            if responseStr.contains("\"behavior\":\"allow\"") || responseStr.contains("\"behavior\":\"always\"") {
                FileHandle.standardOutput.write(Data("{\"decision\":\"allow\"}".utf8))
            } else if responseStr.contains("\"behavior\":\"deny\"") {
                FileHandle.standardOutput.write(Data("{\"decision\":\"deny\"}".utf8))
            } else {
                FileHandle.standardOutput.write(response)
            }
        }
    } else {
        FileHandle.standardOutput.write(response)
    }
}

close(sock)
exit(0)
