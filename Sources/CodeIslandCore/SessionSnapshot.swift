import Foundation

public enum SessionTitleSource: String, Sendable, Codable {
    case codexThreadName
    case claudeCustomTitle
    case claudeAiTitle
    /// The conversation's name in Claude Desktop's Code-tab sidebar.
    case claudeDesktopTitle
}

public struct SessionSnapshot: Sendable {

    public static let supportedSources: Set<String> = [
        "claude",
        "codex",
        "opencode",
        "google-antigravity",
    ]

    /// Desktop-IDE *host* sources. The IDE's own processes appear in the
    /// process ancestry of ANY CLI agent launched from its integrated terminal,
    /// and would be greedily matched by the loose `/<source>` substring rule in
    /// `CLIProcessResolver.sourceMatchesExecutablePath`. They must never be
    /// recovered via ancestry inference: the IDE reports itself through
    /// `--source`. Excluding them keeps Claude Code run inside Antigravity's
    /// terminal from being mis-attributed to Antigravity. (#220)
    public static let ideHostSources: Set<String> = [
        "google-antigravity",
    ]

    public var status: AgentStatus = .idle
    public var currentTool: String?
    public var toolDescription: String?
    public var lastActivity: Date = Date()
    public var cwd: String?
    public var model: String?
    public var permissionMode: String?
    public var toolHistory: [ToolHistoryEntry] = []
    public var totalToolCallCount: Int = 0
    public var subagents: [String: SubagentState] = [:]
    /// Agent ids closed by SubagentStop/Stop/SessionEnd, in insertion order
    /// (newest last). Blocks merge/fold from putting a finished subagent back
    /// on the parent. Live growth is capped at ``maxClosedSubagentIds``;
    /// restored lists may be larger (see ``restoreClosedSubagentIds``).
    /// Mutate only via ``recordClosedSubagentId``, ``clearClosedSubagentId``,
    /// or ``restoreClosedSubagentIds`` so the live cap cannot be bypassed.
    public private(set) var closedSubagentIds: [String] = []
    /// O(1) membership mirror of ``closedSubagentIds`` for hot-path tombstone checks.
    private var closedSubagentIdSet: Set<String> = []
    /// Bound for *live* ``closedSubagentIds`` growth in long-lived sessions.
    /// Persist restore does not apply this cap (see ``restoreClosedSubagentIds``).
    public static let maxClosedSubagentIds = 256
    public var startTime: Date = Date()
    public var lastUserPrompt: String?
    public var lastAssistantMessage: String?
    /// Public assistant text emitted during the active Codex turn. This is
    /// transient UI state: a new turn clears it while chat history remains.
    public var liveCodexOutput: String?
    /// Absolute path to the JSONL transcript currently backing this session. Populated
    /// by hooks (`transcript_path` field) and by filesystem discovery, consumed by the
    /// JSONLTailer for incremental streaming of the latest assistant reply.
    public var transcriptPath: String?
    /// Recent chat messages (max 3) for preview
    public var recentMessages: [ChatMessage] = []
    // Terminal info for window activation
    public var termApp: String?        // "iTerm.app", "Apple_Terminal", etc.
    public var ttyPath: String?         // /dev/ttys00X
    public var termBundleId: String?    // __CFBundleIdentifier for precise terminal ID
    /// Claude Desktop's own id for a Code-tab session (`local_…`, from
    /// CLAUDE_CODE_HOST_SESSION_ID) — what its `claude://code/continue` link
    /// takes to open that exact session instead of just raising the app.
    public var claudeDesktopSessionId: String?
    public var cliPid: pid_t?            // CLI process PID (from bridge _ppid)
    public var cliStartTime: Date?       // Start time of the tracked CLI PID (guards PID reuse)
    public var source: String = "claude" // "claude" or "codex"
    public var interrupted: Bool = false
    /// The last turn ended on an error (Claude Code `StopFailure`); the
    /// card's status reads ERROR until the next prompt. Set by
    /// AppState.enqueueCompletion. Transient.
    public var lastTurnFailed: Bool = false
    public var sessionTitle: String?
    public var sessionTitleSource: SessionTitleSource?
    public var providerSessionId: String?
    /// Checked-out git branch for cwd; refreshed on cwd changes and Stop
    /// (a turn may have switched branches). nil for non-repo and remote cwds.
    public var gitBranch: String?
    public var gitIsWorktree: Bool = false
    /// The agent's own task checklist (TaskCreate/TaskUpdate, TodoWrite,
    /// Codex update_plan), fed by hooks here and by the transcript tailer.
    public var agentTasks = AgentTaskList()
    /// Claude Code's `away_summary` recap of an idle session; cleared by the
    /// next user prompt. See ``SessionRecap``.
    public var recap: SessionRecap?
    /// Reasoning effort of the latest turn ("xhigh", "max", …), read from the
    /// transcript next to the turn's model. Hooks don't report it.
    public var reasoningEffort: String?
    /// When a hook last reported `model`. An attach-time transcript backfill
    /// must not replace it with a model from an older line
    /// (`claude --resume --model X` over a transcript that ran on Y).
    public var modelReportedAt: Date?
    /// What the latest `/model` switch said about the 1M context variant; nil
    /// until one is seen. Transcript lines carry only the bare API id, so this
    /// is the one place a switch *to or from* the `[1m]` variant shows up.
    public var configuredLongContext: Bool?

    public init(startTime: Date = Date()) {
        self.startTime = startTime
    }

    /// Record a closed subagent/Task id (no-op if already present). Evicts the
    /// oldest entries when over ``maxClosedSubagentIds``.
    ///
    /// Callers must serialize access (today: `@MainActor` / main-queue session
    /// mutation). The check-then-append is not atomic across threads the way
    /// `Set.insert` was — do not call off the session-owning queue.
    public mutating func recordClosedSubagentId(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !closedSubagentIdSet.contains(trimmed) else { return }
        closedSubagentIds.append(trimmed)
        closedSubagentIdSet.insert(trimmed)
        let overflow = closedSubagentIds.count - Self.maxClosedSubagentIds
        if overflow > 0 {
            for evicted in closedSubagentIds.prefix(overflow) {
                closedSubagentIdSet.remove(evicted)
            }
            closedSubagentIds.removeFirst(overflow)
        }
    }

    /// Drop a tombstone so the agent/Task may be folded or shown again.
    /// Trims like ``recordClosedSubagentId`` so whitespace-padded ids clear.
    public mutating func clearClosedSubagentId(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard closedSubagentIdSet.remove(trimmed) != nil else { return }
        closedSubagentIds.removeAll { $0 == trimmed }
    }

    /// O(1) tombstone check used on the subagent hook hot path.
    /// Trims like ``recordClosedSubagentId`` / ``clearClosedSubagentId``.
    public func hasClosedSubagentId(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return closedSubagentIdSet.contains(trimmed)
    }

    /// Restore persisted ids in file order **without** applying the live cap.
    ///
    /// Pre-cap builds wrote this array via `Set.sorted()` (lexicographic) — that
    /// order is not recency, so keep-last-N on restore would drop arbitrary
    /// tombstones and allow finished Tasks to re-fold. Disk size already bounds
    /// memory; ``recordClosedSubagentId`` still caps *new* live growth.
    public mutating func restoreClosedSubagentIds(_ ids: [String]) {
        closedSubagentIds = []
        closedSubagentIdSet = []
        closedSubagentIds.reserveCapacity(ids.count)
        closedSubagentIdSet.reserveCapacity(ids.count)
        for id in ids {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !closedSubagentIdSet.contains(trimmed) else { continue }
            closedSubagentIds.append(trimmed)
            closedSubagentIdSet.insert(trimmed)
        }
    }

    public static func normalizedSupportedSource(_ source: String?) -> String? {
        guard let source else { return nil }
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        let aliases: [String: String] = [
            // Google Antigravity (Gemini-based IDE/CLI). Not the "antigravity"
            // Claude Code fork, which Burrow does not track (#215).
            "googleantigravity": "google-antigravity",
            "google antigravity": "google-antigravity",
            "google-anti-gravity": "google-antigravity",
            "antigravity-ide": "google-antigravity",
            "antigravity-cli": "google-antigravity",
            "agy": "google-antigravity",
        ]
        let canonical = aliases[normalized] ?? normalized
        if supportedSources.contains(canonical) { return canonical }
        if canonical.hasPrefix("google-antigravity") || canonical.hasPrefix("googleantigravity") { return "google-antigravity" }
        return nil
    }

    public var activeSubagentCount: Int {
        subagents.values.filter { $0.status != .idle }.count
    }

    public mutating func addRecentMessage(_ msg: ChatMessage, maxCount: Int = 3) {
        recentMessages.append(msg)
        if recentMessages.count > maxCount {
            recentMessages.removeFirst(recentMessages.count - maxCount)
        }
    }

    public mutating func insertRecentMessage(_ msg: ChatMessage, at index: Int, maxCount: Int = 3) {
        recentMessages.insert(msg, at: index)
        if recentMessages.count > maxCount {
            recentMessages.removeFirst(recentMessages.count - maxCount)
        }
    }

    public mutating func recordTool(_ tool: String, description: String?, success: Bool, agentType: String?, maxHistory: Int) {
        totalToolCallCount += 1
        let entry = ToolHistoryEntry(tool: tool, description: description, timestamp: Date(), success: success, agentType: agentType)
        toolHistory.append(entry)
        if toolHistory.count > maxHistory {
            toolHistory.removeFirst()
        }
    }

    /// Display name: project folder, or short session ID
    public var displayName: String {
        guard let cwd = cwd else { return "Session" }
        return Self.resolvedProjectDisplayName(from: cwd)
    }

    /// Directory names that are agent metadata, not user projects. Only these
    /// exact dot-dirs are peeled / treated as unhelpful — legitimate dot-named
    /// repos (.dotfiles, .config, .emacs.d) must keep their own name.
    static let agentMetadataDirNames: Set<String> = [
        ".claude", ".codex", ".gemini", ".opencode", ".codeisland",
    ]

    /// Resolve a human project folder label from a cwd path.
    static func resolvedProjectDisplayName(from cwd: String) -> String {
        var name = (cwd as NSString).lastPathComponent

        // Agent metadata dirs (.claude, .codex) are not project names (#248).
        if Self.agentMetadataDirNames.contains(name) {
            if let peeled = peelProjectNameBeforeMetadataDir(in: cwd, leaf: name) {
                name = peeled
            } else if isUnhelpfulHookCwd(cwd) {
                return "Session"
            }
        }

        if isHomeDirectoryPath(cwd) || isHomeDirectoryBasename(name, for: cwd) {
            return "Session"
        }

        if name.count >= 8 && name.allSatisfy(\.isNumber) {
            let parent = ((cwd as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if !parent.isEmpty && parent != "/" && !isHomeDirectoryBasename(parent, for: cwd) {
                return parent
            }
        }
        return name
    }

    /// When cwd sits inside a metadata dir, peel back to the real project
    /// folder name.
    static func peelProjectNameBeforeMetadataDir(in cwd: String, leaf: String) -> String? {
        guard Self.agentMetadataDirNames.contains(leaf) else { return nil }

        let parent = ((cwd as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let parentPath = (cwd as NSString).deletingLastPathComponent
        if !parent.isEmpty && parent != "/",
           !isHomeDirectoryPath(parentPath) {
            return parent
        }
        return nil
    }

    /// Hook/bridge cwd values that carry no project identity — getcwd() inside
    /// `~/.claude` or at `$HOME` must not block workspace_roots / transcript_path.
    static func isUnhelpfulHookCwd(_ cwd: String) -> Bool {
        if isHomeDirectoryPath(cwd) { return true }
        let last = (cwd as NSString).lastPathComponent
        guard Self.agentMetadataDirNames.contains(last) else { return false }
        return isHomeDirectoryPath((cwd as NSString).deletingLastPathComponent)
    }

    static func isHomeDirectoryPath(_ path: String) -> Bool {
        let home = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).standardizingPath
        return (path as NSString).standardizingPath == home
    }

    static func isHomeDirectoryBasename(_ name: String, for cwd: String) -> Bool {
        name == (FileManager.default.homeDirectoryForCurrentUser.path as NSString).lastPathComponent
            && (isHomeDirectoryPath(cwd) || isUnhelpfulHookCwd(cwd))
    }

    public func displayTitle(sessionId: String) -> String {
        sessionLabel ?? sessionId
    }

    public func displaySessionId(sessionId: String) -> String {
        if let providerSessionId {
            let trimmed = providerSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return sessionId
    }

    public var projectDisplayName: String {
        displayName
    }

    public var sessionLabel: String? {
        guard let sessionTitle else { return nil }
        let trimmed = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Shortened model name: "claude-opus-4-6" → "opus"
    public var shortModelName: String? {
        guard let model = model else { return nil }
        let lower = model.lowercased()
        if lower.contains("opus") { return "opus" }
        if lower.contains("sonnet") { return "sonnet" }
        if lower.contains("haiku") { return "haiku" }
        if lower.contains("gemini") { return "gemini" }
        if let last = model.split(separator: "-").last, last.count <= 8 {
            return String(last)
        }
        return String(model.prefix(8))
    }

    /// Source label for display
    public var sourceLabel: String {
        switch source {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "opencode": return "OpenCode"
        case "google-antigravity": return "Google Antigravity"
        default: return source.capitalized
        }
    }

    public var isCodex: Bool { source == "codex" }
    public var isClaude: Bool { source == "claude" }

    /// True when the session runs inside a native app in APP mode (Codex app, Claude Desktop, etc.)
    /// — the app IS the agent, not just a terminal hosting a CLI.
    /// Requires both bundle ID AND source to match (Claude CLI in Antigravity's terminal ≠ native app mode).
    public var isNativeAppMode: Bool {
        guard let bid = termBundleId else { return false }
        guard let expectedSource = Self.appBundleSources[bid] else { return false }
        return source == expectedSource
    }

    /// True when the session runs inside an IDE's integrated terminal.
    /// We can't query IDE tab/pane state, so notification suppression should be skipped.
    public var isIDETerminal: Bool {
        guard let bid = termBundleId else {
            // Zed rebuilds the environment it gives its integrated terminal, so
            // no __CFBundleIdentifier reaches the hook — TERM_PROGRAM is the only
            // signal left, and without this the session reads as a plain terminal
            // whose tab visibility we would wrongly claim to know (#307).
            return termApp?.lowercased() == "zed"
        }
        if isNativeAppMode { return false }
        // Known apps used as terminal (e.g., Claude CLI in Antigravity's integrated terminal)
        if Self.appBundleNames[bid] != nil { return true }
        let lower = bid.lowercased()
        return lower.contains("vscode") || lower.contains("vscodium")
            || lower.contains("windsurf") || lower.contains("codeium")
            || lower.contains("jetbrains")
            || lower.contains("zed")
            || lower.contains("xcode") || lower == "com.apple.dt.xcode"
            || lower.contains("panic.nova")
            || lower.contains("android.studio")
            || lower.contains("antigravity")
    }

    /// Bundle IDs of native apps (not terminals)
    private static let appBundleNames: [String: String] = [
        "com.openai.codex": "Codex",
        "ai.opencode.desktop": "OpenCode",
        "com.google.antigravity": "Antigravity",
        // Claude Code Desktop (#211): local Code-tab sessions run the same engine
        // and fire the same ~/.claude/settings.json hooks as the CLI.
        "com.anthropic.claudefordesktop": "Claude",
    ]

    /// Maps native app bundle IDs to their expected source identifier.
    /// Used by isNativeAppMode to tell the app's own agent from a CLI in its terminal.
    private static let appBundleSources: [String: String] = [
        "com.openai.codex": "codex",
        "ai.opencode.desktop": "opencode",
        // Google Antigravity IDE — its integrated terminal launches the agy CLI,
        // whose hooks report --source google-antigravity (#215).
        "com.google.antigravity": "google-antigravity",
        // Claude Code Desktop (#211) — hook subprocesses inherit the app's
        // __CFBundleIdentifier, so desktop Code sessions arrive tagged with it.
        "com.anthropic.claudefordesktop": "claude",
    ]

    /// Source id for the native app that owns `bundleId`, if any.
    public static func sourceForAppBundleId(_ bundleId: String) -> String? {
        appBundleSources[bundleId]
    }

    /// Source used for the session-card mascot.
    ///
    /// Prefers the hook/discovery source. When that is missing, fall back to the
    /// native-app bundle map so a Codex desktop session does not render as the
    /// default Claude mascot while the right-hand badge still says Codex.
    public var mascotSource: String {
        if let normalized = Self.normalizedSupportedSource(source) {
            return normalized
        }
        if let bid = termBundleId, let inferred = Self.appBundleSources[bid] {
            return inferred
        }
        return source
    }

    /// True when this is a CLI agent hosted inside another IDE/app terminal
    /// (e.g. Claude Code inside Antigravity) — mascot/badge should follow the CLI,
    /// not the host IDE brand.
    public var isCLIHostedInForeignApp: Bool {
        guard isIDETerminal,
              let src = Self.normalizedSupportedSource(source),
              let bid = termBundleId,
              let hostSource = Self.appBundleSources[bid] else {
            return false
        }
        return src != hostSource
    }

    /// Right-hand session badge text: CLI brand when hosted in a foreign IDE,
    /// otherwise the host terminal/app name.
    public var terminalBadgeLabel: String? {
        if isCLIHostedInForeignApp {
            return sourceLabel
        }
        return terminalName
    }

    /// Short terminal/app name for display tag
    public var terminalName: String? {
        // If termBundleId is a known app, show app name (APP mode)
        if let bid = termBundleId, let name = Self.appBundleNames[bid] {
            return name
        }
        // Check bundle ID for terminal identification (more reliable than TERM_PROGRAM)
        if let bid = termBundleId {
            let lower = bid.lowercased()
            if lower.contains("cmux") { return "cmux" }
            if lower.contains("warp") { return "Warp" }
            if lower == "com.mitchellh.ghostty" { return "Ghostty" }
            if lower.contains("iterm2") { return "iTerm2" }
            if lower.contains("kitty") { return "Kitty" }
            if lower.contains("alacritty") { return "Alacritty" }
            if lower.contains("wezterm") { return "WezTerm" }
            // IDE integrated terminals
            if lower.contains("vscode") || lower.contains("vscodium") { return "VS Code" }
            if lower.contains("windsurf") { return "Windsurf" }
            if lower.contains("jetbrains") {
                if lower.contains("intellij") { return "IDEA" }
                if lower.contains("pycharm") { return "PyCharm" }
                if lower.contains("webstorm") { return "WebStorm" }
                if lower.contains("goland") { return "GoLand" }
                if lower.contains("clion") { return "CLion" }
                if lower.contains("rider") { return "Rider" }
                if lower.contains("rubymine") { return "RubyMine" }
                if lower.contains("phpstorm") { return "PhpStorm" }
                if lower.contains("datagrip") { return "DataGrip" }
                return "JetBrains"
            }
            if lower.contains("zed") { return "Zed" }
            if lower.contains("xcode") || lower == "com.apple.dt.xcode" { return "Xcode" }
            if lower.contains("panic.nova") { return "Nova" }
            if lower.contains("android.studio") { return "Android Studio" }
            if lower.contains("antigravity") { return "Antigravity" }
        }
        // Fallback to TERM_PROGRAM
        guard let app = termApp else { return nil }
        let lower = app.lowercased()
        if lower.contains("cmux") { return "cmux" }
        if lower == "ghostty" { return "Ghostty" }
        if lower.contains("iterm") { return "iTerm2" }
        if lower.contains("warp") { return "Warp" }
        if lower.contains("alacritty") { return "Alacritty" }
        if lower.contains("kitty") { return "Kitty" }
        if lower.contains("terminal") { return "Terminal" }
        return app
    }

    /// Subtitle: cwd path or model info
    public var subtitle: String? {
        if let cwd = cwd {
            // Show parent/folder instead of just folder
            let parts = cwd.split(separator: "/")
            let pathText: String
            if parts.count >= 2 {
                pathText = "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
            } else {
                pathText = cwd
            }
            return pathText
        }
        return model
    }
}

public struct SessionSummary {
    public let status: AgentStatus
    public let primarySource: String
    public let activeSessionCount: Int
    public let totalSessionCount: Int

    public init(status: AgentStatus, primarySource: String, activeSessionCount: Int, totalSessionCount: Int) {
        self.status = status
        self.primarySource = primarySource
        self.activeSessionCount = activeSessionCount
        self.totalSessionCount = totalSessionCount
    }
}

public func deriveSessionSummary(from sessions: [String: SessionSnapshot]) -> SessionSummary {
    var highestStatus: AgentStatus = .idle
    var source = "claude"
    var active = 0
    var mostRecentIdleSource: (source: String, time: Date)?

    for session in sessions.values {
        if session.status != .idle {
            active += 1
        } else if mostRecentIdleSource == nil || session.lastActivity > mostRecentIdleSource!.time {
            mostRecentIdleSource = (session.source, session.lastActivity)
        }

        switch session.status {
        case .waitingApproval:
            highestStatus = .waitingApproval
            source = session.source
        case .waitingQuestion:
            if highestStatus != .waitingApproval {
                highestStatus = .waitingQuestion
                source = session.source
            }
        case .running:
            if highestStatus == .idle || highestStatus == .processing {
                highestStatus = .running
                source = session.source
            }
        case .processing:
            if highestStatus == .idle {
                highestStatus = .processing
                source = session.source
            }
        case .idle:
            break
        }
    }

    if highestStatus == .idle, let idleSource = mostRecentIdleSource?.source {
        source = idleSource
    }

    return SessionSummary(
        status: highestStatus,
        primarySource: source,
        activeSessionCount: active,
        totalSessionCount: sessions.count
    )
}

// MARK: - Side Effects

public enum SideEffect: Equatable {
    case playSound(String)
    case tryMonitorSession(sessionId: String)
    case stopMonitor(sessionId: String)
    case removeSession(sessionId: String)
    case enqueueCompletion(sessionId: String)
    case setActiveSession(sessionId: String?)
}

// MARK: - Pure Reducer

/// Pure reducer: mutates sessions, returns side effects for the caller to execute.
public func reduceEvent(
    sessions: inout [String: SessionSnapshot],
    event: HookEvent,
    maxHistory: Int,
    replyCompletePlaceholder: String = "Reply complete"
) -> [SideEffect] {
    let sessionId = event.sessionId ?? "default"
    let eventName = EventNormalizer.normalize(event.eventName)
    var effects: [SideEffect] = []

    // Ensure session exists
    if sessions[sessionId] == nil {
        sessions[sessionId] = SessionSnapshot()
    }

    // Always update metadata from parent events. Subagent events are routed
    // through the parent session ID, so applying their full metadata here would
    // overwrite the parent's model/transcript/title with child-session values.
    // Still fill *missing* identity fields so a merge-first Task hook does not
    // leave the parent stuck as the default `source == "claude"`.
    if event.agentId == nil {
        extractMetadata(into: &sessions, sessionId: sessionId, event: event)
    } else {
        fillMissingParentMetadataFromSubagentEvent(into: &sessions, sessionId: sessionId, event: event)
    }

    // Codex may flush already queued tool hooks after an Interrupt. Keep the
    // terminal state latched until a new prompt/session starts so stale work
    // cannot revive the card as processing.
    //
    // SubagentStop still passes: interrupting the root turn does not stop
    // spawned agents, and dropping their stop would leave them in `subagents`
    // so the next root Stop sees "active subagents" and pins the card to
    // running/Agent. Removing a subagent never revives an idle parent.
    if sessions[sessionId]?.source == "codex",
       sessions[sessionId]?.interrupted == true,
       eventName != "SessionStart",
       eventName != "UserPromptSubmit",
       eventName != "SessionEnd",
       eventName != "SubagentStop",
       eventName != "Interrupt" {
        return effects
    }

    // Route subagent-specific events
    if let agentId = event.agentId {
        // Subagents and teammates share the parent's task list: their
        // TaskUpdate calls move the parent's rows too. Their own creates stay
        // off the parent card (see applySharedUpdates).
        let sharedTaskEvents = AgentTaskHookParser.events(from: event, normalizedEventName: eventName)
        if !sharedTaskEvents.isEmpty {
            sessions[sessionId]?.agentTasks.applySharedUpdates(sharedTaskEvents, now: Date())
        }
        let parentBefore = sessions[sessionId]
        let effectsBefore = effects.count
        let handled = handleSubagentEvent(
            sessions: &sessions,
            sessionId: sessionId,
            agentId: agentId,
            eventName: eventName,
            event: event,
            maxHistory: maxHistory,
            effects: &effects
        )
        recordSubagentModel(sessions: &sessions, sessionId: sessionId, agentId: agentId, event: event)
        if let parentBefore {
            keepBackgroundClaudeAgentQuiet(sessions: &sessions, sessionId: sessionId, agentId: agentId,
                                           parentBefore: parentBefore, effects: &effects, effectsBefore: effectsBefore)
        }
        if handled { return effects }
    }

    // Remote Codex hooks can enrich ordinary lifecycle events with the latest
    // public assistant text because their transcript path is not readable on
    // this Mac. Apply it only after stale/interrupted and subagent events have
    // been filtered, and keep it separate from persisted chat history.
    if sessions[sessionId]?.source == "codex",
       eventName != "UserPromptSubmit",
       eventName != "SessionStart",
       let output = event.rawJSON["last_assistant_message"] as? String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            sessions[sessionId]?.liveCodexOutput = trimmed
        }
    }

    // Preserve actionable states: don't let activity updates overwrite waiting states
    let isWaiting = sessions[sessionId]?.status == .waitingApproval
        || sessions[sessionId]?.status == .waitingQuestion

    // Agent checklist progress. Subagent tool events were consumed by
    // handleSubagentEvent above (after their shared-list updates), so a
    // child's own list never lands here.
    let agentTasksBeforeEvent = sessions[sessionId]?.agentTasks
    let agentTaskEvents = AgentTaskHookParser.events(from: event, normalizedEventName: eventName)
    if !agentTaskEvents.isEmpty {
        sessions[sessionId]?.agentTasks.apply(agentTaskEvents, now: Date())
    }

    // Update this session's state
    switch eventName {
    case "UserPromptSubmit":
        sessions[sessionId]?.interrupted = false
        sessions[sessionId]?.lastTurnFailed = false
        sessions[sessionId]?.clearRecapIfSuperseded(byPromptAt: Date())
        if sessions[sessionId]?.source == "codex" {
            sessions[sessionId]?.liveCodexOutput = nil
        }
        sessions[sessionId]?.status = .processing
        sessions[sessionId]?.currentTool = nil
        sessions[sessionId]?.toolDescription = nil
        // Probe a wider set of field names + nested containers: most agents put
        // the prompt at "prompt" top-level, others nest it inside `input` /
        // `data` / `payload` / `params`. Empty strings are skipped
        // so we don't insert blank chat rows when a hook fires with a placeholder.
        // Leading `<system-reminder>` spans are context the host injected
        // (Claude Desktop prepends one), not what the user typed.
        let prompt = firstStringFromEvent(
            event,
            keys: ["prompt", "user_prompt", "userPrompt", "user_message", "message", "input", "content", "text"],
            includeNested: true
        ).map { JSONLTailer.stripDisplayWrappers($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        if let prompt {
            sessions[sessionId]?.lastUserPrompt = prompt
            if sessions[sessionId]?.recentMessages.last?.isUser == true {
                sessions[sessionId]?.recentMessages.removeLast()
            }
            sessions[sessionId]?.addRecentMessage(ChatMessage(isUser: true, text: prompt))
        }
    case "PreToolUse":
        if !isWaiting {
            sessions[sessionId]?.status = .running
            sessions[sessionId]?.currentTool = event.activityLabel
            sessions[sessionId]?.toolDescription = event.toolDescription
        }
    case "PostToolUse":
        if let tool = sessions[sessionId]?.currentTool {
            let desc = sessions[sessionId]?.toolDescription
            sessions[sessionId]?.recordTool(tool, description: desc, success: true, agentType: nil, maxHistory: maxHistory)
        }
        if !isWaiting {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
    case "PostToolUseFailure":
        if let tool = sessions[sessionId]?.currentTool {
            let desc = sessions[sessionId]?.toolDescription
            sessions[sessionId]?.recordTool(tool, description: desc, success: false, agentType: nil, maxHistory: maxHistory)
        }
        if !isWaiting {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
    case "PermissionDenied":
        if !isWaiting {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
    case "SubagentStart":
        if !isWaiting {
            sessions[sessionId]?.status = .running
            sessions[sessionId]?.currentTool = "Agent"
            sessions[sessionId]?.toolDescription = event.rawJSON["agent_type"] as? String
        }
    case "SubagentStop":
        if !isWaiting {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
    case "Stop":
        // Detect ESC/Ctrl+C interruption
        let stopReason = event.rawJSON["stop_reason"] as? String ?? ""
        let wasInterrupted = (stopReason == "user" || stopReason == "interrupted")
        let hasActiveSubagents = sessions[sessionId]?.subagents.values.contains {
            $0.status != .idle && !$0.outsideParentTurn
        } == true
        let assistantMsg = firstStringFromEvent(
            event,
            keys: ["last_assistant_message", "text", "message", "summary"],
            includeNested: true
        )
        if let msg = assistantMsg {
            sessions[sessionId]?.lastAssistantMessage = msg
            // Stop's last_assistant_message (Claude Code, Codex, mcode, …) is
            // often the reply the transcript tailer already appended, and with
            // maxCount 3 a duplicate crowds a real row off the card. Skip it
            // only when that reply is the newest row: after a new prompt, the
            // same text is a new answer and still lands.
            let alreadyShown = sessions[sessionId]?.recentMessages.last.map {
                !$0.isUser && $0.text == msg
            } ?? false
            if !alreadyShown {
                sessions[sessionId]?.addRecentMessage(ChatMessage(isUser: false, text: msg))
            }
        } else if sessions[sessionId]?.lastAssistantMessage == nil,
                  sessions[sessionId]?.recentMessages.last?.isUser == true {
            // No reply content from the hook -- add placeholder
            sessions[sessionId]?.addRecentMessage(ChatMessage(isUser: false, text: replyCompletePlaceholder))
        }
        // Try to capture user prompt from Stop event if not already set
        if sessions[sessionId]?.lastUserPrompt == nil {
            if let prompt = event.rawJSON["last_user_message"] as? String {
                sessions[sessionId]?.lastUserPrompt = prompt
                let insertAt = max(0, (sessions[sessionId]?.recentMessages.count ?? 1) - 1)
                sessions[sessionId]?.insertRecentMessage(ChatMessage(isUser: true, text: prompt), at: insertAt)
            }
        }

        // Parent chat Stop while folded Tasks are still working — keep the card
        // active and do not pop a premature completion.
        if hasActiveSubagents {
            if !isWaiting {
                sessions[sessionId]?.status = .running
                if sessions[sessionId]?.currentTool == nil {
                    sessions[sessionId]?.currentTool = "Agent"
                }
            }
            // Do not latch `interrupted` onto a still-active parent+Task card.
        } else {
            sessions[sessionId]?.interrupted = wasInterrupted
            sessions[sessionId]?.status = .idle
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
            effects.append(.enqueueCompletion(sessionId: sessionId))
        }
    case "SessionStart":
        effects.append(.stopMonitor(sessionId: sessionId))
        sessions[sessionId] = SessionSnapshot(startTime: Date())
        // Re-apply metadata from this event (common extraction above wrote to the old session)
        if let cwd = event.rawJSON["cwd"] as? String, !cwd.isEmpty { sessions[sessionId]?.cwd = cwd }
        if let model = hookReportedModel(event) {
            sessions[sessionId]?.model = model
            sessions[sessionId]?.modelReportedAt = Date()
        }
        if let ppid = event.rawJSON["_ppid"] as? Int, ppid > 0 {
            let newPid = pid_t(ppid)
            if sessions[sessionId]?.cliPid != newPid {
                sessions[sessionId]?.cliPid = newPid
                sessions[sessionId]?.cliStartTime = nil
            }
        }
        if let source = SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String) {
            sessions[sessionId]?.source = source
        }
        if let app = event.rawJSON["_term_app"] as? String, !app.isEmpty { sessions[sessionId]?.termApp = app }
        if let bundle = event.rawJSON["_term_bundle"] as? String, !bundle.isEmpty { sessions[sessionId]?.termBundleId = bundle }
        if let tty = event.rawJSON["_tty"] as? String, !tty.isEmpty { sessions[sessionId]?.ttyPath = tty }
        if let mode = event.rawJSON["permission_mode"] as? String { sessions[sessionId]?.permissionMode = mode }
        if let roots = event.rawJSON["workspace_roots"] as? [String], let first = roots.first, !first.isEmpty {
            sessions[sessionId]?.cwd = first
        }
        if let hostId = claudeDesktopSessionId(in: event) {
            sessions[sessionId]?.claudeDesktopSessionId = hostId
        }
        if let env = event.rawJSON["_env"] as? [String: String] {
            applyEnvMetadata(into: &sessions, sessionId: sessionId, env: env)
        }
        if let providerSessionId = event.rawJSON["session_id"] as? String,
           !providerSessionId.isEmpty,
           sessions[sessionId]?.source == "codex",
           sessions[sessionId]?.termBundleId == "com.openai.codex" {
            sessions[sessionId]?.providerSessionId = normalizedCodexDesktopProviderSessionId(providerSessionId)
        }
        if let sessionTitle = event.rawJSON["session_title"] as? String,
           !sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sessions[sessionId]?.sessionTitle = sessionTitle
        }
        effects.append(.tryMonitorSession(sessionId: sessionId))
    case "SessionEnd":
        // Side effect: AppState handles pending permission deny before removal
        effects.append(.removeSession(sessionId: sessionId))
        return effects
    case "Notification":
        let notificationText = firstStringFromEvent(
            event,
            keys: ["message", "text", "summary", "status", "detail"],
            includeNested: true
        )
        if let msg = notificationText, !msg.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            sessions[sessionId]?.toolDescription = msg
        }
        if QuestionPayload.from(event: event) != nil {
            sessions[sessionId]?.status = .waitingQuestion
        } else {
            // Notifications that describe what the agent is waiting for. A
            // Notification cannot block (it is observe-only), so this is a
            // display-only wait: the decision is made in the terminal, and the
            // next PostToolUse/Stop clears it via the existing wasWaiting drain.
            // Without this the card sat on "thinking" while the CLI was in fact
            // blocked on the user (#290).
            switch notificationKind(from: event) {
            case "permission_prompt":
                sessions[sessionId]?.status = .waitingApproval
            case "idle_prompt":
                // "Waiting for your input after 60s idle" — the turn is over.
                sessions[sessionId]?.status = .idle
            default:
                break
            }
        }
    case "PreCompact":
        sessions[sessionId]?.status = .processing
        if sessions[sessionId]?.source == "codex" {
            sessions[sessionId]?.currentTool = "Compacting"
        }
        sessions[sessionId]?.toolDescription = "Compacting context\u{2026}"
    case "PostCompact":
        if !isWaiting {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
    case "Interrupt":
        sessions[sessionId]?.interrupted = true
        sessions[sessionId]?.status = .idle
        sessions[sessionId]?.currentTool = nil
        sessions[sessionId]?.toolDescription = nil
        effects.append(.enqueueCompletion(sessionId: sessionId))
    default:
        break
    }

    // SessionStart rebuilt the snapshot, but a resumed or compacted
    // conversation is still working through the same checklist. /clear
    // starts the conversation over — even when it keeps the session id — so
    // the old checklist goes with it.
    if eventName == "SessionStart", let agentTasksBeforeEvent,
       (event.rawJSON["source"] as? String)?.lowercased() != "clear" {
        sessions[sessionId]?.agentTasks = agentTasksBeforeEvent
    }

    sessions[sessionId]?.lastActivity = Date()

    // Ensure process monitor is set up (covers sessions created implicitly)
    if sessions[sessionId]?.cwd != nil {
        effects.append(.tryMonitorSession(sessionId: sessionId))
    }

    // Trigger sound for this event. A single failed tool stays silent; only a
    // turn that died (StopFailure) rings the error sound. See EventSoundRouting.
    if let sound = EventSoundRouting.soundEvent(rawEventName: event.eventName, normalizedEventName: eventName) {
        effects.append(.playSound(sound))
    }

    // Switch display to the session that just had activity
    if eventName == "Stop" {
        // Stop event: keep activeSessionId on completed session (set by enqueueCompletion)
    } else if sessions[sessionId]?.status != .idle {
        effects.append(.setActiveSession(sessionId: sessionId))
    }
    // Note: the "else if activeSessionId == sessionId → mostActive" case
    // is handled by AppState since it needs to check current activeSessionId

    return effects
}

// MARK: - Private Helpers

private func applyEnvMetadata(into sessions: inout [String: SessionSnapshot], sessionId: String, env: [String: String]) {
    if sessions[sessionId]?.termApp == nil,
       let app = env["TERM_PROGRAM"], !app.isEmpty {
        sessions[sessionId]?.termApp = app
    }
    if sessions[sessionId]?.termBundleId == nil,
       let bundle = env["__CFBundleIdentifier"], !bundle.isEmpty {
        sessions[sessionId]?.termBundleId = bundle
    }
    if sessions[sessionId]?.claudeDesktopSessionId == nil,
       let host = env[ClaudeDesktopCodeSession.hostSessionEnvKey],
       ClaudeDesktopCodeSession.isValidHostSessionId(host) {
        sessions[sessionId]?.claudeDesktopSessionId = host
    }
}

/// Fill identity fields on a parent card from a merged Task/subagent hook.
/// Unlike `extractMetadata`, never overwrites values already set on the parent
/// (child payloads can carry Task-specific cwd/model/title).
public func fillMissingParentMetadataFromSubagentEvent(
    into sessions: inout [String: SessionSnapshot],
    sessionId: String,
    event: HookEvent
) {
    // Default SessionSnapshot.source is "claude". Upgrade when the hook carries a
    // real source.
    if sessions[sessionId]?.source == "claude",
       let source = SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String)
        ?? SessionSnapshot.normalizedSupportedSource(event.rawJSON["source"] as? String),
       source != "claude" {
        sessions[sessionId]?.source = source
    }

    let cwdMissing = sessions[sessionId]?.cwd == nil
        || SessionSnapshot.isUnhelpfulHookCwd(sessions[sessionId]?.cwd ?? "")
    if cwdMissing {
        if let cwd = event.rawJSON["cwd"] as? String, !cwd.isEmpty,
           !SessionSnapshot.isUnhelpfulHookCwd(cwd) {
            sessions[sessionId]?.cwd = cwd
        } else if let roots = event.rawJSON["workspace_roots"] as? [String],
                  let first = roots.first, !first.isEmpty {
            sessions[sessionId]?.cwd = first
        }
    }

    // Claude child hooks carry the parent's transcript; a Codex
    // child's is its own rollout. Tailing that as the parent's would label
    // the parent with the child's model and effort.
    if sessions[sessionId]?.transcriptPath == nil,
       !isCodexSubagentEvent(event, session: sessions[sessionId]),
       let transcriptPath = event.rawJSON["transcript_path"] as? String, !transcriptPath.isEmpty {
        sessions[sessionId]?.transcriptPath = transcriptPath
    }

    if sessions[sessionId]?.cliPid == nil,
       let ppid = event.rawJSON["_ppid"] as? Int, ppid > 0 {
        sessions[sessionId]?.cliPid = pid_t(ppid)
    }

    // A subagent runs inside the parent's CLI, so it carries the same id.
    if sessions[sessionId]?.claudeDesktopSessionId == nil,
       let hostId = claudeDesktopSessionId(in: event) {
        sessions[sessionId]?.claudeDesktopSessionId = hostId
    }
}

/// The Claude Desktop Code-tab id the bridge forwarded from
/// CLAUDE_CODE_HOST_SESSION_ID. Only a well-formed id is kept: it ends up in
/// a URL on click.
private func claudeDesktopSessionId(in event: HookEvent) -> String? {
    guard let hostId = event.rawJSON["_claude_desktop_session"] as? String,
          ClaudeDesktopCodeSession.isValidHostSessionId(hostId) else { return nil }
    return hostId
}

/// Whether a subagent-routed event comes from Codex (native child threads).
private func isCodexSubagentEvent(_ event: HookEvent, session: SessionSnapshot?) -> Bool {
    let source = SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String)
        ?? session?.source
    return source == "codex"
}

public func extractMetadata(into sessions: inout [String: SessionSnapshot], sessionId: String, event: HookEvent) {
    let eventCwd = event.rawJSON["cwd"] as? String
    if let cwd = eventCwd, !cwd.isEmpty,
       !SessionSnapshot.isUnhelpfulHookCwd(cwd) {
        sessions[sessionId]?.cwd = cwd
    }
    if sessions[sessionId]?.cwd == nil
        || SessionSnapshot.isUnhelpfulHookCwd(sessions[sessionId]?.cwd ?? ""),
       let roots = event.rawJSON["workspace_roots"] as? [String],
       let first = roots.first, !first.isEmpty {
        sessions[sessionId]?.cwd = first
    } else if sessions[sessionId]?.cwd == nil, let cwd = eventCwd, !cwd.isEmpty {
        // Last resort: an unhelpful cwd ($HOME, ~/.claude) still beats nil —
        // transcript-based model lookup keys off it, and the display layer
        // already renders these paths as "Session".
        sessions[sessionId]?.cwd = cwd
    }
    // Git branch resolution is NOT done here: this reducer runs on the main
    // actor and .git probing can block on network mounts. AppState refreshes
    // it asynchronously after reduce (maybeRefreshGitBranch).
    if let model = hookReportedModel(event) {
        sessions[sessionId]?.model = model
        sessions[sessionId]?.modelReportedAt = Date()
    }
    if let mode = event.rawJSON["permission_mode"] as? String {
        sessions[sessionId]?.permissionMode = mode
    }
    // Hooks frequently include the absolute transcript path — capture it so the tailer
    // can attach to live appends without needing a filesystem scan to rediscover it.
    if let transcriptPath = event.rawJSON["transcript_path"] as? String, !transcriptPath.isEmpty {
        sessions[sessionId]?.transcriptPath = transcriptPath
    }
    // Terminal info (injected by hook script)
    if let app = event.rawJSON["_term_app"] as? String, !app.isEmpty, app != "unknown" {
        sessions[sessionId]?.termApp = app
    }
    if let tty = event.rawJSON["_tty"] as? String, !tty.isEmpty {
        sessions[sessionId]?.ttyPath = tty
    }
    if let bundle = event.rawJSON["_term_bundle"] as? String, !bundle.isEmpty {
        sessions[sessionId]?.termBundleId = bundle
    }
    // Fallback: extract terminal/multiplexer info from _env sub-object (direct plugin format)
    if let env = event.rawJSON["_env"] as? [String: String] {
        applyEnvMetadata(into: &sessions, sessionId: sessionId, env: env)
    }
    if let ppid = event.rawJSON["_ppid"] as? Int, ppid > 0 {
        let newPid = pid_t(ppid)
        if sessions[sessionId]?.cliPid != newPid {
            sessions[sessionId]?.cliPid = newPid
            sessions[sessionId]?.cliStartTime = nil
        }
    }
    if let source = SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String) {
        sessions[sessionId]?.source = source
    }
    // Claude Desktop Code-tab session id (injected by bridge from
    // CLAUDE_CODE_HOST_SESSION_ID).
    if let hostId = claudeDesktopSessionId(in: event) {
        sessions[sessionId]?.claudeDesktopSessionId = hostId
    }
    if let providerSessionId = event.rawJSON["session_id"] as? String,
       !providerSessionId.isEmpty,
       sessions[sessionId]?.source == "codex",
       sessions[sessionId]?.termBundleId == "com.openai.codex" {
        sessions[sessionId]?.providerSessionId = normalizedCodexDesktopProviderSessionId(providerSessionId)
    }
    if let sessionTitle = event.rawJSON["session_title"] as? String,
       !sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        sessions[sessionId]?.sessionTitle = sessionTitle
    }
}

private func normalizedCodexDesktopProviderSessionId(_ sessionId: String) -> String {
    let prefix = "codexapp:"
    guard sessionId.hasPrefix(prefix) else { return sessionId }
    return String(sessionId.dropFirst(prefix.count))
}

/// Pull a non-empty string from a hook JSON value.
/// Supports plain strings and content-part arrays such as Kimi Code CLI's
/// `prompt: [{ "type": "text", "text": "..." }]`.
private func stringFromHookJSONValue(_ value: Any?) -> String? {
    if let value = value as? String {
        // Trim only to detect empty / whitespace-only payloads; return the
        // original value so callers preserve any leading/trailing
        // whitespace inside code-snippet prompts and multi-line content.
        return value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
            ? nil : value
    }

    let parts: [[String: Any]]
    if let typed = value as? [[String: Any]] {
        parts = typed
    } else if let anyParts = value as? [Any] {
        parts = anyParts.compactMap { $0 as? [String: Any] }
        if parts.isEmpty { return nil }
    } else {
        return nil
    }

    let texts = parts.compactMap { part -> String? in
        if let type = part["type"] as? String, type != "text" { return nil }
        guard let text = part["text"] as? String,
              !text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }
    let joined = texts.joined()
    return joined.isEmpty ? nil : joined
}

/// The model a hook names.
private func hookReportedModel(_ event: HookEvent) -> String? {
    guard let model = event.rawJSON["model"] as? String, !model.isEmpty else { return nil }
    return model
}

private func firstStringFromDict(_ dict: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let value = stringFromHookJSONValue(dict[key]) {
            return value
        }
    }
    return nil
}

/// Lowercased `notification_type` for a Notification event, if it carries one.
/// e.g. `permission_prompt` / `idle_prompt` / `auth_success`; agents that do
/// not send it leave this nil. (#290)
public func notificationKind(from event: HookEvent) -> String? {
    guard let raw = firstStringFromEvent(
        event,
        keys: ["notification_type", "notificationType"],
        includeNested: true
    ) else { return nil }
    let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()
    return trimmed.isEmpty ? nil : trimmed
}

private func firstStringFromEvent(_ event: HookEvent, keys: [String], includeNested: Bool) -> String? {
    if let value = firstStringFromDict(event.rawJSON, keys: keys) {
        return value
    }
    if includeNested {
        for containerKey in ["payload", "data"] {
            if let nested = event.rawJSON[containerKey] as? [String: Any],
               let value = firstStringFromDict(nested, keys: keys) {
                return value
            }
        }
    }
    return nil
}

private func subagentType(from event: HookEvent) -> String {
    firstStringFromEvent(event, keys: ["agent_type", "agentType"], includeNested: false) ?? "Agent"
}

private func ensureSubagent(
    sessions: inout [String: SessionSnapshot],
    sessionId: String,
    agentId: String,
    event: HookEvent
) -> Bool {
    // Only SubagentStart/SessionStart may reopen a closed agent id. Later
    // tool/response hooks with the same agent_id must not revive it.
    if sessions[sessionId]?.hasClosedSubagentId(agentId) == true {
        return false
    }
    if sessions[sessionId]?.subagents[agentId] == nil {
        sessions[sessionId]?.subagents[agentId] = SubagentState(
            agentId: agentId,
            agentType: subagentType(from: event)
        )
    }
    return true
}

/// Keep a child's own `model` (Codex child threads report it on their hooks)
/// on its SubagentState. The parent's model is never used as a stand-in —
/// `extractMetadata` is skipped for subagent events for the same reason.
private func recordSubagentModel(
    sessions: inout [String: SessionSnapshot],
    sessionId: String,
    agentId: String,
    event: HookEvent
) {
    guard sessions[sessionId]?.subagents[agentId] != nil,
          let model = (event.rawJSON["model"] as? String)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
          !model.isEmpty else { return }
    sessions[sessionId]?.subagents[agentId]?.model = model
}

/// Claude Code runs agents of its own once a turn is over — none of them a
/// Task the conversation is waiting on. An agent first seen while its Claude
/// parent is idle keeps its own state, but its hooks never wake the parent:
/// before this an idle conversation sat on "thinking" for good, since its CLI
/// is alive and nothing times it out (Burrow design/v20). A request for the
/// user still surfaces.
private func keepBackgroundClaudeAgentQuiet(
    sessions: inout [String: SessionSnapshot],
    sessionId: String,
    agentId: String,
    parentBefore: SessionSnapshot,
    effects: inout [SideEffect],
    effectsBefore: Int
) {
    let known = parentBefore.subagents[agentId]
    let background = known?.outsideParentTurn == true
        || (known == nil && parentBefore.isClaude && parentBefore.status == .idle)
    guard background, var parent = sessions[sessionId] else { return }
    parent.subagents[agentId]?.outsideParentTurn = true
    if parent.status != .waitingApproval && parent.status != .waitingQuestion {
        parent.status = parentBefore.status
        parent.currentTool = parentBefore.currentTool
        parent.toolDescription = parentBefore.toolDescription
        parent.lastActivity = parentBefore.lastActivity
        effects.removeSubrange(effectsBefore...)
    }
    sessions[sessionId] = parent
}

/// Handle subagent events. Returns true if the event was consumed.
private func handleSubagentEvent(
    sessions: inout [String: SessionSnapshot],
    sessionId: String,
    agentId: String,
    eventName: String,
    event: HookEvent,
    maxHistory: Int,
    effects: inout [SideEffect]
) -> Bool {
    switch eventName {
    case "SubagentStart", "SessionStart":
        let agentType = subagentType(from: event)
        sessions[sessionId]?.clearClosedSubagentId(agentId)
        sessions[sessionId]?.subagents[agentId] = SubagentState(
            agentId: agentId,
            agentType: agentType
        )
        // Subagent spawned — parent session is actively processing
        if sessions[sessionId]?.status == .idle || sessions[sessionId]?.status == .processing {
            sessions[sessionId]?.status = .running
            sessions[sessionId]?.currentTool = "Agent"
            sessions[sessionId]?.toolDescription = agentType
        }
        sessions[sessionId]?.lastActivity = Date()
        effects.append(.setActiveSession(sessionId: sessionId))
        return true

    case "UserPromptSubmit":
        guard ensureSubagent(sessions: &sessions, sessionId: sessionId, agentId: agentId, event: event) else {
            return true
        }
        sessions[sessionId]?.subagents[agentId]?.status = .processing
        sessions[sessionId]?.subagents[agentId]?.lastActivity = Date()
        if sessions[sessionId]?.status != .waitingApproval && sessions[sessionId]?.status != .waitingQuestion {
            let agentType = sessions[sessionId]?.subagents[agentId]?.agentType
            sessions[sessionId]?.status = .running
            sessions[sessionId]?.currentTool = "Agent"
            sessions[sessionId]?.toolDescription = agentType
        }
        sessions[sessionId]?.lastActivity = Date()
        effects.append(.setActiveSession(sessionId: sessionId))
        return true

    case "SubagentStop", "Stop", "SessionEnd":
        sessions[sessionId]?.subagents.removeValue(forKey: agentId)
        // Codex fires SubagentStop at the end of every child *turn*, and its
        // agent_id is the child's thread id, reused for follow-up turns sent
        // via send_message / followup_task without a new SubagentStart. A
        // tombstone here would drop those turns' hooks (ensureSubagent) and
        // auto-deny their PermissionRequests (shouldSuppressClosedSubagentUI).
        // Removing the entry is enough: Codex awaits each hook in order, so no
        // stale tool hook can trail the stop, and the next turn's hooks
        // recreate the entry.
        if !(eventName == "SubagentStop" && isCodexSubagentEvent(event, session: sessions[sessionId])) {
            sessions[sessionId]?.recordClosedSubagentId(agentId)
        }
        // If no more subagents, revert parent to processing (waiting for main thread to continue)
        if sessions[sessionId]?.subagents.isEmpty == true {
            if sessions[sessionId]?.status == .running && sessions[sessionId]?.currentTool == "Agent" {
                sessions[sessionId]?.status = .processing
                sessions[sessionId]?.currentTool = nil
                sessions[sessionId]?.toolDescription = nil
            }
        }
        sessions[sessionId]?.lastActivity = Date()
        return true

    case "PreToolUse":
        guard ensureSubagent(sessions: &sessions, sessionId: sessionId, agentId: agentId, event: event) else {
            return true
        }
        sessions[sessionId]?.subagents[agentId]?.status = .running
        sessions[sessionId]?.subagents[agentId]?.currentTool = event.activityLabel
        sessions[sessionId]?.subagents[agentId]?.toolDescription = event.toolDescription
        sessions[sessionId]?.subagents[agentId]?.lastActivity = Date()
        // Keep parent session showing as active while subagents work
        if sessions[sessionId]?.status != .waitingApproval && sessions[sessionId]?.status != .waitingQuestion {
            sessions[sessionId]?.status = .running
        }
        sessions[sessionId]?.lastActivity = Date()
        return true

    case "PostToolUse":
        guard ensureSubagent(sessions: &sessions, sessionId: sessionId, agentId: agentId, event: event) else {
            return true
        }
        if let tool = sessions[sessionId]?.subagents[agentId]?.currentTool {
            let agentType = sessions[sessionId]?.subagents[agentId]?.agentType
            let desc = sessions[sessionId]?.subagents[agentId]?.toolDescription
            sessions[sessionId]?.recordTool(tool, description: desc, success: true, agentType: agentType, maxHistory: maxHistory)
        }
        sessions[sessionId]?.subagents[agentId]?.status = .processing
        sessions[sessionId]?.subagents[agentId]?.currentTool = nil
        sessions[sessionId]?.subagents[agentId]?.toolDescription = nil
        sessions[sessionId]?.subagents[agentId]?.lastActivity = Date()
        sessions[sessionId]?.lastActivity = Date()
        return true

    case "PostToolUseFailure":
        guard ensureSubagent(sessions: &sessions, sessionId: sessionId, agentId: agentId, event: event) else {
            return true
        }
        if let tool = sessions[sessionId]?.subagents[agentId]?.currentTool {
            let agentType = sessions[sessionId]?.subagents[agentId]?.agentType
            let desc = sessions[sessionId]?.subagents[agentId]?.toolDescription
            sessions[sessionId]?.recordTool(tool, description: desc, success: false, agentType: agentType, maxHistory: maxHistory)
        }
        sessions[sessionId]?.subagents[agentId]?.status = .processing
        sessions[sessionId]?.subagents[agentId]?.currentTool = nil
        sessions[sessionId]?.subagents[agentId]?.toolDescription = nil
        sessions[sessionId]?.lastActivity = Date()
        return true

    case "Notification":
        // Keep subagents' ask/question notifications on the parent card.
        guard ensureSubagent(sessions: &sessions, sessionId: sessionId, agentId: agentId, event: event) else {
            return true
        }
        sessions[sessionId]?.subagents[agentId]?.lastActivity = Date()
        sessions[sessionId]?.lastActivity = Date()
        let notificationText = firstStringFromEvent(
            event,
            keys: ["message", "text", "summary", "status", "detail"],
            includeNested: true
        )
        if let msg = notificationText, !msg.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            sessions[sessionId]?.toolDescription = msg
            sessions[sessionId]?.subagents[agentId]?.toolDescription = msg
        }
        if QuestionPayload.from(event: event) != nil {
            sessions[sessionId]?.status = .waitingQuestion
            sessions[sessionId]?.subagents[agentId]?.status = .waitingQuestion
            effects.append(.setActiveSession(sessionId: sessionId))
        } else if sessions[sessionId]?.status != .waitingApproval
            && sessions[sessionId]?.status != .waitingQuestion
            && sessions[sessionId]?.status != .running {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.subagents[agentId]?.status = .processing
        }
        return true

    default:
        return false  // Fall through to normal session handling
    }
}
