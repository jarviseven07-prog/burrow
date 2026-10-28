import Foundation
import Network
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "HookServer")

@MainActor
class HookServer {
    enum RouteKind: Equatable {
        case permission
        case question
        case event
    }

    private let appState: AppState
    nonisolated static var socketPath: String { SocketPath.path }
    private var listener: NWListener?

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        // Clean up stale socket
        unlink(HookServer.socketPath)

        // Set umask to 0o077 BEFORE the listener creates the socket file,
        // ensuring it is never world-readable even briefly (closes TOCTOU window).
        let previousUmask = umask(0o077)

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: HookServer.socketPath)

        do {
            listener = try NWListener(using: params)
        } catch {
            umask(previousUmask)
            log.error("Failed to create NWListener: \(error.localizedDescription)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }

        listener?.stateUpdateHandler = { [previousUmask] state in
            switch state {
            case .ready:
                // Restore previous umask now that the socket file exists with safe permissions
                umask(previousUmask)
                // Belt-and-suspenders: explicitly set 0o700 in case umask didn't take effect
                chmod(HookServer.socketPath, 0o700)
                log.info("HookServer listening on \(HookServer.socketPath)")
            case .failed(let error):
                umask(previousUmask)
                log.error("HookServer failed: \(error.localizedDescription)")
            default:
                break
            }
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        // Delay socket removal so in-flight hooks can finish sending their payload
        // before the file disappears — prevents intermittent errors on session end (#45).
        let path = HookServer.socketPath
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            unlink(path)
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveAll(connection: connection, accumulated: Data())
    }

    private static let maxPayloadSize = 10_485_760  // 10MB safety limit

    /// Recursively receive all data until EOF, then process
    private func receiveAll(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self = self else { return }

                // On error with no data, just drop the connection
                if error != nil && accumulated.isEmpty && content == nil {
                    connection.cancel()
                    return
                }

                var data = accumulated
                if let content { data.append(content) }

                // Safety: reject oversized payloads
                if data.count > Self.maxPayloadSize {
                    log.warning("Payload too large (\(data.count) bytes), dropping connection")
                    let denyResponse = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
                    self.sendResponse(connection: connection, data: denyResponse)
                    return
                }

                if isComplete || error != nil {
                    self.processRequest(data: data, connection: connection)
                } else {
                    self.receiveAll(connection: connection, accumulated: data)
                }
            }
        }
    }

    /// Internal tools that are safe to auto-approve without user confirmation.
    /// Read from user settings; defaults to all known internal tools.
    private static var autoApproveTools: Set<String> {
        SettingsManager.shared.autoApproveTools
    }

    /// Whether this event's agent is on the user's always-proceed list (#283).
    /// Matched on both the raw `_source` and its normalized form so "agy",
    /// "google-antigravity" and "antigravity-cli" all resolve to one entry.
    static func isAutoApprovedSource(_ event: HookEvent) -> Bool {
        isAutoApprovedSource(event, approved: SettingsManager.shared.autoApproveSources)
    }

    nonisolated static func isAutoApprovedSource(
        _ event: HookEvent,
        approved: Set<String>
    ) -> Bool {
        guard !approved.isEmpty,
              let raw = event.rawJSON["_source"] as? String else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        if approved.contains(trimmed) { return true }
        guard let normalized = SessionSnapshot.normalizedSupportedSource(trimmed) else { return false }
        return approved.contains(normalized)
    }

    /// User-configured cwd substring blocklist for plugin/background hooks (e.g. claude-mem).
    /// Empty default = no filtering. Trimmed, blank entries skipped.
    private static func eventMatchesExcludedCwd(_ cwd: String) -> Bool {
        cwdMatchesAnyPattern(cwd, patternsCSV: SettingsManager.shared.excludedHookCwdSubstrings)
    }

    /// Pure substring blocklist match — returns true if `cwd` contains any
    /// non-empty trimmed entry of `patternsCSV`. Extracted for testability;
    /// `nonisolated` because it touches no actor state.
    nonisolated static func cwdMatchesAnyPattern(_ cwd: String, patternsCSV: String) -> Bool {
        guard !patternsCSV.isEmpty else { return false }
        for entry in patternsCSV.split(separator: ",", omittingEmptySubsequences: false) {
            let pattern = entry.trimmingCharacters(in: .whitespaces)
            if !pattern.isEmpty, cwd.contains(pattern) { return true }
        }
        return false
    }

    private static func hiddenPluginResponse(for raw: [String: Any]) -> Data {
        // Hidden PermissionRequest must allow so the plugin's tool execution
        // doesn't block waiting on a UI prompt the user said to suppress.
        let eventName = (raw["hook_event_name"] as? String
            ?? raw["hookEventName"] as? String
            ?? raw["event_name"] as? String
            ?? "").lowercased()
        if eventName.contains("permission") {
            return Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#.utf8)
        }
        return Data("{}".utf8)
    }

    private static func pluginPpid(from raw: [String: Any]) -> Int? {
        let parsed: Int?
        if let p = raw["_ppid"] as? Int {
            parsed = p
        } else if let p = raw["_ppid"] as? NSNumber {
            parsed = p.intValue
        } else if let s = raw["_ppid"] as? String {
            parsed = Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            parsed = nil
        }
        guard let parsed, parsed > 0 else { return nil }
        return parsed
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func rawSessionId(from raw: [String: Any]) -> String? {
        nonEmptyString(raw["session_id"]) ?? nonEmptyString(raw["sessionId"])
    }

    private static func rawEventName(from raw: [String: Any]) -> String? {
        nonEmptyString(raw["hook_event_name"])
            ?? nonEmptyString(raw["hookEventName"])
            ?? nonEmptyString(raw["event_name"])
            ?? nonEmptyString(raw["eventName"])
    }

    static func routeKind(for event: HookEvent) -> RouteKind {
        let normalizedEventName = EventNormalizer.normalize(event.eventName)
        // Google Antigravity's PreToolUse stays a plain activity event. Its hook
        // cannot approve a call (an `allow` is ignored and Antigravity prompts
        // anyway), so an island card in front of it only doubled every approval
        // and left a card behind when the user answered in Antigravity. The
        // bridge has already told Antigravity to decide for itself (#339).
        if normalizedEventName == "PermissionRequest" {
            return .permission
        }
        if normalizedEventName == "Notification", QuestionPayload.from(event: event) != nil {
            return .question
        }
        return .event
    }

    nonisolated static func shouldDeferPermissionRequestToProvider(_ event: HookEvent) -> Bool {
        guard EventNormalizer.normalize(event.eventName) == "PermissionRequest",
              event.toolName != "AskUserQuestion" else {
            return false
        }
        return CodexPermissionRules.shouldDeferToCodexAutoReview(for: event)
    }

    private static let pluginMarkerBytes = Data("_via_plugin".utf8)
    private static let sourceMarkerBytes = Data(#""_source""#.utf8)
    private static let codexMarkerBytes = Data("codex".utf8)

    private static func codexSubagentMetadata(from raw: [String: Any]) -> CodexSubagentMetadata? {
        guard let path = nonEmptyString(raw["transcript_path"]) else { return nil }
        return AppState.codexSubagentMetadata(inTranscriptPath: path)
    }

    func codexNativeSubsessionParentId(from raw: [String: Any]) -> String? {
        guard (raw["_via_plugin"] as? Bool) != true,
              SessionSnapshot.normalizedSupportedSource(raw["_source"] as? String) == "codex",
              let childSessionId = Self.rawSessionId(from: raw) else {
            return nil
        }

        if let metadata = Self.codexSubagentMetadata(from: raw),
           let parentSessionId = appState.findCodexParentSessionId(
               providerSessionId: metadata.parentThreadId,
               childTermBundleId: raw["_term_bundle"] as? String
           ) {
            return parentSessionId
        }

        // Every Codex Desktop thread runs in the one shared app-server, so a
        // same-PID card says nothing about parentage there (it can even be the
        // thread's own card). Desktop children are found by metadata above.
        guard raw["_term_bundle"] as? String != AppState.codexAppBundleId,
              let ppid = Self.pluginPpid(from: raw) else { return nil }

        // Current Codex hook payloads do not expose parent session metadata for
        // native subagents, but child sessions run inside the same Codex CLI
        // process as their parent. Require an already-active same-PID Codex
        // session so a normal follow-up thread in an idle process stays separate.
        let hasExplicitSubagentMarker = Self.nonEmptyString(raw["agent_id"]) != nil
        return appState.findSessionId(
            forSource: "codex",
            ppid: ppid,
            excluding: childSessionId,
            requireActive: !hasExplicitSubagentMarker
        )
    }

    /// Test seam for Agent Sub-Sessions pre-routing (Codex / plugin).
    internal func routeSubsessionPayloadIfNeededForTesting(
        data: Data
    ) -> (processedData: Data, responseData: Data?) {
        routeSubsessionPayloadIfNeeded(data: data)
    }

    private func routeSubsessionPayloadIfNeeded(data: Data) -> (processedData: Data, responseData: Data?) {
        let mayNeedPluginOrCodex = data.range(of: Self.pluginMarkerBytes) != nil
            || (data.range(of: Self.sourceMarkerBytes) != nil && data.range(of: Self.codexMarkerBytes) != nil)

        let mode = UserDefaults.standard.string(forKey: SettingsKey.pluginSessionMode)
            ?? SettingsDefaults.pluginSessionMode
        let isMergeOrHide = mode == "hide" || mode == "merge"

        guard mayNeedPluginOrCodex,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (data, nil)
        }

        guard isMergeOrHide else {
            return (data, nil)
        }

        if (raw["_via_plugin"] as? Bool) == true {
            switch mode {
            case "hide":
                return (data, Self.hiddenPluginResponse(for: raw))
            case "merge":
                if let source = raw["_source"] as? String,
                   let ppid = Self.pluginPpid(from: raw),
                   let mainSessionId = appState.findSessionId(forSource: source, ppid: ppid) {
                    var rewritten = raw
                    rewritten["session_id"] = mainSessionId
                    if let newData = try? JSONSerialization.data(withJSONObject: rewritten) {
                        return (newData, nil)
                    }
                }
            default:
                break
            }
            return (data, nil)
        }

        guard let childSessionId = Self.rawSessionId(from: raw) else {
            return (data, nil)
        }
        let codexMetadata = Self.codexSubagentMetadata(from: raw)
        let parentSessionId = codexNativeSubsessionParentId(from: raw)
        guard codexMetadata != nil || parentSessionId != nil else {
            return (data, nil)
        }

        switch mode {
        case "hide":
            // Hiding the card must not approve what Codex's auto reviewer
            // would otherwise judge (#165): hand it back undecided instead.
            if Self.rawEventName(from: raw).map(EventNormalizer.normalize) == "PermissionRequest",
               let event = HookEvent(from: data),
               Self.shouldDeferPermissionRequestToProvider(event) {
                return (data, Data("{}".utf8))
            }
            return (data, Self.hiddenPluginResponse(for: raw))
        case "merge":
            guard let parentSessionId else { return (data, nil) }
            var rewritten = raw
            rewritten["session_id"] = parentSessionId
            rewritten["agent_id"] = Self.nonEmptyString(raw["agent_id"]) ?? childSessionId
            rewritten["agent_type"] = Self.nonEmptyString(raw["agent_type"])
                ?? codexMetadata?.agentType
                ?? "default"
            rewritten["_codex_subagent"] = true
            rewritten["_codex_subagent_session_id"] = childSessionId
            if let eventName = Self.rawEventName(from: raw) {
                rewritten["_codex_subagent_event"] = EventNormalizer.normalize(eventName)
            }
            if let newData = try? JSONSerialization.data(withJSONObject: rewritten) {
                return (newData, nil)
            }
        default:
            break
        }
        return (data, nil)
    }

    private func processRequest(data: Data, connection: NWConnection) {
        // Sub-session pre-filter (#123, #151): plugin and Codex child hooks
        // follow Agent Sub-Sessions — merge into the parent, hide, or keep
        // separate.
        //
        // Cheap byte probes first; avoid JSONSerialization on every PostToolUse.
        let routed = routeSubsessionPayloadIfNeeded(data: data)
        if let responseData = routed.responseData {
            sendResponse(connection: connection, data: responseData)
            return
        }
        let processedData = routed.processedData

        guard let event = HookEvent(from: processedData) else {
            sendResponse(connection: connection, data: Data("{\"error\":\"parse_failed\"}".utf8))
            return
        }

        // Diagnostics ring buffer (#103): record the post-merge view of the
        // event so the export reflects what was actually dispatched. Also
        // capture the field names the hook arrived with and a prompt preview
        // so future "prompt not showing" reports can be diagnosed without
        // round-tripping for more data.
        let payloadKeys = event.rawJSON.keys
            .filter { !$0.hasPrefix("_") }  // drop bridge-injected metadata fields
            .sorted()
        let promptPreview: String? = {
            let candidates = ["prompt", "user_prompt", "userPrompt", "message", "input", "content", "text"]
            for key in candidates {
                if let s = event.rawJSON[key] as? String {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return String(trimmed.prefix(80))
                    }
                }
            }
            return nil
        }()
        appState.recordHookEvent(
            source: event.rawJSON["_source"] as? String,
            sessionId: event.sessionId,
            eventName: event.eventName,
            toolName: event.toolName,
            viaPlugin: (event.rawJSON["_via_plugin"] as? Bool) == true,
            payloadKeys: payloadKeys,
            promptPreview: promptPreview
        )

        if let rawSource = event.rawJSON["_source"] as? String,
           SessionSnapshot.normalizedSupportedSource(rawSource) == nil {
            sendResponse(connection: connection, data: Data("{}".utf8))
            return
        }

        // User-configured cwd exclusion: drop hooks fired by background plugins
        // (e.g. claude-mem, agent loops) whose cwd matches any user-provided
        // substring. Default empty list = no filtering, matches existing behavior. (#125)
        if let cwd = event.rawJSON["cwd"] as? String,
           !cwd.isEmpty,
           Self.eventMatchesExcludedCwd(cwd) {
            sendResponse(connection: connection, data: Data("{}".utf8))
            return
        }

        switch Self.routeKind(for: event) {
        case .permission:
            let sessionId = event.sessionId ?? "default"

            // Auto-approve safe internal tools without showing UI
            if let toolName = event.toolName, Self.autoApproveTools.contains(toolName) {
                let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
                sendResponse(connection: connection, data: Data(response.utf8))
                return
            }

            // Agents the user has already put in an always-proceed mode
            // (Antigravity Turbo, …). Re-asking on the island is the
            // exact interruption that mode exists to remove (#283). Questions are
            // not permissions, so AskUserQuestion is deliberately excluded below.
            if event.toolName != "AskUserQuestion",
               Self.isAutoApprovedSource(event) {
                let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
                sendResponse(connection: connection, data: Data(response.utf8))
                return
            }

            // AskUserQuestion is a question, not a permission — route to QuestionBar
            if event.toolName == "AskUserQuestion" {
                monitorPeerDisconnect(connection: connection, sessionId: sessionId, agentId: event.agentId)
                Task {
                    let responseBody = await withCheckedContinuation { continuation in
                        appState.handleAskUserQuestion(event, continuation: continuation)
                    }
                    self.sendResponse(connection: connection, data: responseBody)
                }
                return
            }

            if Self.shouldDeferPermissionRequestToProvider(event) {
                sendResponse(connection: connection, data: Data("{}".utf8))
                return
            }

            monitorPeerDisconnect(connection: connection, sessionId: sessionId, agentId: event.agentId)
            Task {
                let responseBody = await withCheckedContinuation { continuation in
                    appState.handlePermissionRequest(event, continuation: continuation)
                }
                self.sendResponse(connection: connection, data: responseBody)
            }

        case .question:
            let questionSessionId = event.sessionId ?? "default"
            monitorPeerDisconnect(connection: connection, sessionId: questionSessionId, agentId: event.agentId)
            Task {
                let responseBody = await withCheckedContinuation { continuation in
                    appState.handleQuestion(event, continuation: continuation)
                }
                self.sendResponse(connection: connection, data: responseBody)
            }

        case .event:
            appState.handleEvent(event)
            sendResponse(connection: connection, data: Data("{}".utf8))
        }
    }

    /// Per-connection state used by the disconnect monitor.
    /// `responded` flips to true once we've sent the response, so our own
    /// `connection.cancel()` inside `sendResponse` does not masquerade as a
    /// peer disconnect.
    private final class ConnectionContext {
        var responded: Bool = false
    }

    private var connectionContexts: [ObjectIdentifier: ConnectionContext] = [:]

    /// Watch for bridge process disconnect — indicates the bridge process actually died
    /// (e.g. user Ctrl-C'd Claude Code), NOT a normal half-close.
    ///
    /// Previously this used `connection.receive(min:1, max:1)` which triggered on EOF.
    /// But the bridge always does `shutdown(SHUT_WR)` after sending the request (see
    /// CodeIslandBridge/main.swift), which produces an immediate EOF on the read side.
    /// That caused every PermissionRequest to be auto-drained as `deny` before the UI
    /// card was even visible. We now rely on `stateUpdateHandler` transitioning to
    /// `cancelled`/`failed` — which only happens on real socket teardown, not half-close.
    private func monitorPeerDisconnect(connection: NWConnection, sessionId: String, agentId: String?) {
        let context = ConnectionContext()
        let connId = ObjectIdentifier(connection)
        connectionContexts[connId] = context

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self = self else { return }
                switch state {
                case .cancelled, .failed:
                    if !context.responded {
                        self.appState.handlePeerDisconnect(sessionId: sessionId, agentId: agentId)
                    }
                    self.connectionContexts.removeValue(forKey: connId)
                default:
                    break
                }
            }
        }

        // Safety net: if the connection context is still around after 5 minutes
        // (e.g. stuck continuation, NWConnection never transitions), clean it up.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000_000)  // 5 minutes
            guard let self = self else { return }
            if self.connectionContexts.removeValue(forKey: connId) != nil {
                log.warning("Connection context for session \(sessionId) timed out — cleaning up")
                if !context.responded {
                    connection.cancel()
                }
            }
        }
    }

    private func sendResponse(connection: NWConnection, data: Data) {
        // Mark as responded BEFORE cancel() so the disconnect monitor ignores our own teardown.
        if let context = connectionContexts[ObjectIdentifier(connection)] {
            context.responded = true
        }
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
