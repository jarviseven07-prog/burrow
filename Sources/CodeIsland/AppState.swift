import SwiftUI
import CoreServices
import os.log
import SQLite3
import CryptoKit
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "AppState")

/// FSEventStream context target. Callbacks hold an unretained pointer to this
/// box (not `AppState`), and reach the owner only through `weak`, so queued
/// main-queue deliveries stay safe if `AppState` tears down off the main actor.
private final class ProjectsWatcherBox: @unchecked Sendable {
    weak var appState: AppState?
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func handleChange() {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        guard !isCancelled else { return }
        appState?.handleProjectsDirChange()
    }
}

struct CodexSubagentMetadata: Equatable, Sendable {
    let parentThreadId: String
    let agentType: String?
    let agentNickname: String?
}

private struct CodexSpawnEdgeRecord {
    let metadata: CodexSubagentMetadata
    let status: String?
    let transcriptPath: String?
}

private enum CodexTranscriptSubagentInspection {
    /// The first line could not be established as a valid `session_meta`.
    case unavailable
    /// A valid root `session_meta` explicitly contains no subagent relation.
    case root
    case subagent(CodexSubagentMetadata)
}

struct ProcessIdentity: Equatable {
    let pid: pid_t
    let startTime: Date?
}

struct CodexDiscoveryIdentity: Equatable, Sendable {
    let sessionId: String
    let providerSessionId: String?
    let termBundleId: String?
}

struct CodexProcessDiscoveryCandidate: Sendable {
    let pid: pid_t
    let cwd: String?
    let startTime: Date?
    let isDesktop: Bool
}

enum CodexTranscriptOrigin: Equatable, Sendable {
    case desktop
    case cli
    case unknown
}

/// A Codex Desktop thread recovered from Codex's local state database.
///
/// Recent Codex Desktop builds run their app-server with `/` as the process CWD,
/// so the CLI discovery path cannot map that process back to a project. Keeping
/// this small value type separate lets discovery hydrate native-app sessions from
/// the authoritative state DB without exposing the private `DiscoveredSession`.
struct CodexDesktopThreadRecord: Sendable {
    let sessionId: String
    let cwd: String
    let model: String?
    let modifiedAt: Date
    let recentMessages: [ChatMessage]
    let transcriptPath: String
    let status: AgentStatus
    let subagentMetadata: CodexSubagentMetadata?
    let subagentStatus: String?
}

@MainActor
@Observable
final class AppState {
    /// Snapshot of a hook event accepted by HookServer, kept for diagnostics
    /// export (#103). Stored in a fixed-size ring so we can attach the recent
    /// hook stream to bug reports without pulling in full payloads.
    ///
    /// `payloadKeys` lists the top-level JSON field names the hook arrived
    /// with (sorted, no values), and `promptPreview` is a 80-char prefix of
    /// any extracted user prompt. Together those let us tell at a glance
    /// whether a hook fired with an empty / missing prompt vs. fired with a
    /// prompt that the UI then dropped.
    struct DiagnosticHookEvent: Sendable {
        let timestamp: Date
        let source: String?
        let sessionId: String?
        let eventName: String
        let toolName: String?
        let viaPlugin: Bool
        let payloadKeys: [String]
        let promptPreview: String?
    }

    var sessions: [String: SessionSnapshot] = [:]
    var activeSessionId: String?
    var permissionQueue: [PermissionRequest] = []
    var questionQueue: [QuestionRequest] = [] {
        didSet {
            // A close lasts as long as its request: once answered, skipped or
            // drained, its id is forgotten.
            if !dismissedQuestionIds.isEmpty {
                let queued = Set(questionQueue.map(\.id))
                if !dismissedQuestionIds.isSubset(of: queued) {
                    dismissedQuestionIds.formIntersection(queued)
                }
            }
        }
    }
    /// Which side of the notch each agent's pet lives on (BurrowLip).
    @ObservationIgnored let burrowSides = BurrowSideMemory()

    @ObservationIgnored
    private(set) var recentHookEvents: [DiagnosticHookEvent] = []
    @ObservationIgnored
    private let maxRecentHookEvents = 100
    @ObservationIgnored
    var questionTerminalFrontmostDetector: (SessionSnapshot) -> Bool =
        TerminalVisibilityDetector.isTerminalFrontmostForSession

    func recordHookEvent(
        source: String?,
        sessionId: String?,
        eventName: String,
        toolName: String?,
        viaPlugin: Bool,
        payloadKeys: [String],
        promptPreview: String?
    ) {
        recentHookEvents.append(DiagnosticHookEvent(
            timestamp: Date(),
            source: source,
            sessionId: sessionId,
            eventName: eventName,
            toolName: toolName,
            viaPlugin: viaPlugin,
            payloadKeys: payloadKeys,
            promptPreview: promptPreview
        ))
        if recentHookEvents.count > maxRecentHookEvents {
            recentHookEvents.removeFirst(recentHookEvents.count - maxRecentHookEvents)
        }
    }
    /// Cache of in-flight PreToolUse records keyed by tool_use_id. Used to correlate
    /// permission requests back to their originating tool call. See AppState+ToolUseCache.
    @ObservationIgnored
    var pendingToolUses: [String: PreToolUseRecord] = [:]
    /// Records the transcript path currently watched for each session so we only
    /// reattach when the path actually changes. See AppState+TranscriptTailer.
    @ObservationIgnored
    var attachedTranscriptPaths: [String: String] = [:]
    /// Token for the exact JSONLTailer attachment currently owned by a session.
    /// A queued delta from an older attachment must not mutate a same-id session
    /// that was closed and subsequently re-created.
    @ObservationIgnored
    var attachedTranscriptTokens: [String: UUID] = [:]
    /// Attach-time checklist scans still running off the main actor, keyed by
    /// session. See AppState+AgentTasks.
    @ObservationIgnored
    var pendingAgentTaskBackfills: [String: PendingAgentTaskBackfill] = [:]
    /// Watches active session transcripts for appended assistant lines. Lazily
    /// constructed so the delta handler can safely capture `self`.
    @ObservationIgnored
    lazy var transcriptTailer: JSONLTailer = JSONLTailer { [weak self] delta in
        Task { @MainActor in
            self?.applyTranscriptDelta(delta)
        }
    }
    /// Active JSON-RPC client connected to `codex app-server`, or nil when
    /// Codex Desktop isn't running. See AppState+CodexAppServer.
    @ObservationIgnored
    var codexAppServerClient: CodexAppServerClient?
    /// NSWorkspace launch/terminate observers tracking Codex Desktop.
    @ObservationIgnored
    var codexAppServerObservers: [NSObjectProtocol]?
    /// Backoff loop used when the auxiliary app-server exits while the Desktop
    /// host remains open.
    @ObservationIgnored
    nonisolated(unsafe) var codexAppServerReconnectTask: Task<Void, Never>?
    /// Prevent an in-flight/stale state-DB scan from recreating a thread after
    /// app-server delivered `thread/closed`.
    @ObservationIgnored
    var closedCodexAppThreads: [String: Date] = [:]

    /// Computed: first item in permission queue (backward compat for UI reads)
    var pendingPermission: PermissionRequest? { permissionQueue.first }
    /// Computed: first item in question queue
    var pendingQuestion: QuestionRequest? { questionQueue.first }

    /// The queued request belonging to a specific session. A card is addressed
    /// by session, so it must render (and resolve) that session's request
    /// rather than whatever currently sits at the head of the queue. (#308)
    func pendingPermission(forSession sessionId: String) -> PermissionRequest? {
        permissionQueue.first { ($0.event.sessionId ?? "default") == sessionId }
    }

    func pendingQuestion(forSession sessionId: String) -> QuestionRequest? {
        questionQueue.first { ($0.event.sessionId ?? "default") == sessionId }
    }

    /// 1-based position for a card's "N of M" label. The card may be showing a
    /// request that is not the head, so the position has to be looked up. (#308)
    func permissionQueuePosition(forSession sessionId: String) -> Int {
        (permissionQueue.firstIndex { ($0.event.sessionId ?? "default") == sessionId } ?? 0) + 1
    }

    func questionQueuePosition(forSession sessionId: String) -> Int {
        (questionQueue.firstIndex { ($0.event.sessionId ?? "default") == sessionId } ?? 0) + 1
    }
    /// Preview-only: mock question payload for DebugHarness (no continuation needed)
    var previewQuestionPayload: QuestionPayload?
    var surface: IslandSurface = .collapsed {
        didSet {
            // Any expansion counts as "seen" for the glance completion dot.
            if surface.isExpanded, glanceCompletionActive {
                glanceDismissTask?.cancel()
                glanceCompletionActive = false
            }
            // Opening the den (or leaving it) is a look at every conversation:
            // the embers of failed turns and the sparks of finished ones go out.
            // The den itself still marks what finished since the look before.
            if surface == .sessionList, oldValue != .sessionList {
                denLookBefore = denSeenAt
            }
            if surface == .sessionList || oldValue == .sessionList {
                denSeenAt = Date()
                markFinishedConversationsSeen(at: denSeenAt)
            }
            // The den always opens on its front; the back closes with it.
            if surface != .sessionList { denShowsSettings = false }
            switch surface {
            case .approvalCard(let sid): cardRequestId = pendingPermission(forSession: sid)?.id
            case .questionCard(let sid): cardRequestId = pendingQuestion(forSession: sid)?.id
            case .collapsed, .sessionList, .completionCard: cardRequestId = nil
            }
        }
    }

    /// When the den was last open. A turn that failed after this still has
    /// its ember beside the notch (BurrowEmber), one that finished its spark
    /// (BurrowSpark).
    var denSeenAt: Date = .distantPast
    /// `denSeenAt` as it was when the open den was opened: its rows mark the
    /// turns that finished since then.
    var denLookBefore: Date = .distantPast
    /// When each conversation's last turn finished without failing, seen
    /// live (a restored conversation has none, so it brings no spark).
    var turnDoneAt: [String: Date] = [:]
    /// The den is turned over to its back, Burrow's settings (design/v21).
    /// It stays open when the pointer leaves; a click elsewhere closes it.
    var denShowsSettings = false

    /// Settings: the den, turned over. The gear, ⌘, and the menu bar item.
    func showSettings() {
        if surface != .sessionList {
            surface = .sessionList
            cancelCompletionQueue()
        }
        denShowsSettings = true
    }

    /// When the den first showed each conversation after its last turn
    /// finished; the idle sweep counts from here (`isStaleIdleSession`).
    var idleSeenAt: [String: Date] = [:]

    private func markFinishedConversationsSeen(at now: Date) {
        for (sessionId, session) in sessions where session.status == .idle {
            if let seen = idleSeenAt[sessionId], seen >= session.lastActivity { continue }
            idleSeenAt[sessionId] = now
        }
    }

    /// The request the approval / question card on screen was opened for.
    /// While that very request still waits, re-evaluating the queue leaves
    /// the card alone — it may be one the user picked that is not the head.
    /// Once it is answered, the session's next request filling the same card
    /// is weighed like any other.
    @ObservationIgnored
    private var cardRequestId: UUID?

    /// Index of the approval the card on screen still shows, when it is
    /// still waiting and visible.
    private var shownApprovalIndex: Int? {
        guard let cardRequestId, case .approvalCard(let sid) = surface,
              !dismissedPermissionSessionIds.contains(sid),
              pendingPermission(forSession: sid)?.id == cardRequestId else { return nil }
        return permissionQueue.firstIndex { $0.id == cardRequestId }
    }

    /// The session of the question card on screen, when the question it was
    /// opened for still waits.
    private var shownQuestionSessionId: String? {
        guard let cardRequestId, case .questionCard(let sid) = surface,
              pendingQuestion(forSession: sid)?.id == cardRequestId else { return nil }
        return sid
    }

    /// Glance completion mode: an agent finished while the pill was collapsed —
    /// light the dot instead of expanding. Cleared when the user expands the
    /// panel, with a long failsafe so a missed dot never lingers forever.
    var glanceCompletionActive = false
    private var glanceDismissTask: Task<Void, Never>?

    var justCompletedSessionId: String? {
        if case .completionCard(let id) = surface { return id }
        return nil
    }

    private var maxHistory: Int { SettingsManager.shared.maxToolHistory }
    /// Torn down from `deinit`, which may run off the main actor (e.g. async
    /// XCTest ARC). Only mutated on the main actor while `self` is alive.
    @ObservationIgnored
    nonisolated(unsafe) private var cleanupTimer: Timer?
    private var autoCollapseTask: Task<Void, Never>?
    /// How long a completion card stays up on its own: the user's setting.
    /// Tests shorten it.
    @ObservationIgnored
    private var completionAutoCollapseDelayOverride: TimeInterval?
    var completionAutoCollapseDelay: TimeInterval {
        get {
            completionAutoCollapseDelayOverride ?? CompletionCardDuration.seconds(
                forSetting: UserDefaults.standard.double(forKey: SettingsKey.completionCardDuration)
            )
        }
        set { completionAutoCollapseDelayOverride = newValue }
    }
    private var completionQueue: [String] = []
    /// Mouse must enter the panel before auto-collapse is allowed (prevents instant dismiss)
    var completionHasBeenEntered = false
    /// Auto-collapse timer fired but mouse is inside panel — defer collapse until mouse leaves
    var deferCollapseOnMouseLeave = false
    /// `attachParentPid` is the monitored process's ppid captured when the monitor was
    /// attached. Processes that already had ppid <= 1 at attach time are launchd-managed
    /// daemons (e.g. a Hermes gateway with KeepAlive=true), NOT orphans of a closed
    /// terminal — they must never be terminated by orphan cleanup (#243).
    /// Cancelled from `deinit` off the main actor.
    @ObservationIgnored
    nonisolated(unsafe) private var processMonitors: [String: (source: DispatchSourceProcess, process: ProcessIdentity, attachParentPid: pid_t?)] = [:]
    private var exitingSessions: [String: ProcessIdentity] = [:]
    @ObservationIgnored
    nonisolated(unsafe) private var saveTimer: Timer?
    @ObservationIgnored
    nonisolated(unsafe) private var fsEventStream: FSEventStreamRef?
    @ObservationIgnored
    nonisolated(unsafe) private var projectsWatcherBox: ProjectsWatcherBox?
    private var lastFSScanTime: Date = .distantPast
    @ObservationIgnored
    nonisolated(unsafe) private var discoveryScanTask: Task<Void, Never>?
    private var pendingDiscoveryRescan = false
    @ObservationIgnored
    nonisolated(unsafe) private var codexDesktopDiscoveryScanTask: Task<Void, Never>?
    private var lastCodexDesktopDiscoveryPollAt: Date?
    private var isShowingCompletion: Bool {
        if case .completionCard = surface { return true }
        return false
    }
    /// True when an interactive card (approval or question) is visible — completions must queue.
    private var isShowingInteractive: Bool {
        switch surface {
        case .approvalCard, .questionCard: return true
        default: return false
        }
    }
    private var modelReadRetryAt: [String: Date] = [:]
    /// Per parent session → subagent id: the subagent's own model/effort once
    /// read from its transcript, and the reads still trying to find it.
    @ObservationIgnored
    var subagentModelObservations: [String: [String: ModelObservation]] = [:]
    @ObservationIgnored
    var subagentModelReads: [String: [String: SubagentModelRead]] = [:]

    private var dismissedPermissionSessionIds: Set<String> = []
    private func nextVisiblePermissionIndex() -> Int? {
        permissionQueue.firstIndex { request in
            let sid = request.event.sessionId ?? "default"
            return !dismissedPermissionSessionIds.contains(sid)
        }
    }

    /// Sessions whose approval is still waiting on the user: queued and not
    /// dismissed. Dismissing hides a request without dequeuing it (#309), so
    /// the queue alone would keep reminding about a prompt the user hid.
    var visiblePermissionSessionIds: Set<String> {
        Set(permissionQueue.map { $0.event.sessionId ?? "default" })
            .subtracting(dismissedPermissionSessionIds)
    }

    /// The request each of those sessions' approval card shows — its first
    /// queued one — by session.
    var visiblePermissionRequestIds: [String: String] {
        var ids: [String: String] = [:]
        for request in permissionQueue {
            let sid = request.event.sessionId ?? "default"
            guard ids[sid] == nil, !dismissedPermissionSessionIds.contains(sid) else { continue }
            ids[sid] = request.id.uuidString
        }
        return ids
    }

    /// Question requests the user closed without answering. Unlike approvals
    /// these are keyed by request, not session: a new question from the same
    /// session is a new thing to see. Hidden, never resolved — the agent keeps
    /// waiting, and the collapsed bar's question badge reopens the card.
    private(set) var dismissedQuestionIds: Set<UUID> = []

    /// The question each session's card shows — its first queued one — in
    /// queue order, for the sessions whose card the user has not closed. That
    /// first question decides: a later one from the same session (a
    /// subagent's) waits behind a closed card instead of reopening it on the
    /// question the user just put away.
    private var visibleQuestionCards: [QuestionRequest] {
        var seen = Set<String>()
        return questionQueue.filter { request in
            seen.insert(request.event.sessionId ?? "default").inserted
                && !dismissedQuestionIds.contains(request.id)
        }
    }

    /// The first question whose card the user has not closed — what may open
    /// by itself, and what a question shortcut acts on.
    var nextVisibleQuestion: QuestionRequest? {
        visibleQuestionCards.first
    }

    /// Question counterpart of `visiblePermissionRequestIds`: closed cards are
    /// left out.
    var pendingQuestionRequestIds: [String: String] {
        var ids: [String: String] = [:]
        for request in visibleQuestionCards {
            ids[request.event.sessionId ?? "default"] = request.id.uuidString
        }
        return ids
    }

    var rotatingSessionId: String?
    var rotatingSession: SessionSnapshot? {
        guard let rid = rotatingSessionId else { return nil }
        return sessions[rid]
    }
    @ObservationIgnored
    nonisolated(unsafe) private var rotationTimer: Timer?

    private func startCleanupTimer() {
        guard cleanupTimer == nil else { return }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupIdleSessions()
            }
        }
    }

    /// Minutes a finished conversation stays once the den has shown it.
    nonisolated static let seenIdleGraceMinutes = 3

    /// Whether the idle sweep removes an idle card. A finished conversation
    /// stays until the den has shown it (`idleSeenAt`), then
    /// `seenIdleGraceMinutes` more: its spark sends you to the den, so its
    /// row must still be there however long you were away. A card whose
    /// process exits goes with it (`handleProcessExit`), seen or not.
    nonisolated static func isStaleIdleSession(lastActivity: Date, seenAt: Date?, now: Date = Date()) -> Bool {
        guard let seenAt, seenAt >= lastActivity else { return false }
        return now.timeIntervalSince(seenAt) >= TimeInterval(seenIdleGraceMinutes * 60)
    }

    private func cleanupIdleSessions() {
        // 1. Verify monitored PIDs are still alive (DispatchSource can silently miss exits)
        //    Also kill orphaned processes (ppid <= 1, terminal closed but process survived).
        var deadMonitors: [(String, ProcessIdentity)] = []
        var orphaned: [(String, pid_t)] = []
        for (sessionId, monitor) in processMonitors {
            let process = monitor.process
            let pid = process.pid
            // Check if the monitored process is still the same live process.
            if !Self.isLiveProcess(process) {
                deadMonitors.append((sessionId, process))
                continue
            }
            // Check for orphaned processes: ppid <= 1 now, but only if the process had a
            // real parent when we attached. A process whose ppid was already <= 1 at attach
            // time is a launchd-managed daemon, not a terminal orphan — killing it puts
            // KeepAlive daemons into a SIGTERM/restart loop (#243).
            if Self.isReparentedOrphan(currentParentPid: Self.parentPid(of: pid), attachParentPid: monitor.attachParentPid)
                && shouldTerminateOrphanedProcess(sessionId: sessionId, pid: pid) {
                orphaned.append((sessionId, pid))
            }
        }
        for (sessionId, process) in deadMonitors {
            // PID gone but monitor didn't fire — treat as process exit so session is removed
            // promptly (after 5s grace) instead of lingering for 10 minutes.
            handleProcessExit(sessionId: sessionId, exitedProcess: process)
        }
        for (sessionId, pid) in orphaned {
            log.notice("⚠️ terminating reparented orphan pid=\(pid, privacy: .public) session=\(sessionId, privacy: .public)")
            kill(pid, SIGTERM)
            removeSession(sessionId)
        }

        // 2. Reset likely-stuck sessions only when we have no process monitor.
        //    If the process is still monitored/alive, trust explicit Stop/SessionEnd or
        //    process exit instead of synthesizing idle and risking false-idle mid-thought.
        //    - No tool + no monitor: 300s (agents can think for several minutes)
        //    - Has tool + no monitor: 180s (long build / deep thinking with missed exit)
        //    - waitingApproval/Question + no monitor: 300s (connection likely dropped)
        for (key, session) in sessions
            where processMonitors[key] == nil
            && session.status != .idle {
            let elapsed = -session.lastActivity.timeIntervalSinceNow
            let threshold: TimeInterval
            switch session.status {
            case .waitingApproval, .waitingQuestion: threshold = 300
            default: threshold = session.currentTool != nil ? 180 : 300
            }
            if elapsed > threshold {
                // A silent Claude turn is not a stuck one: ask its transcript.
                if session.isClaude,
                   session.status == .processing || session.status == .running,
                   let turn = Self.claudeTranscriptTurn(atPath: session.transcriptPath),
                   turn == .open, elapsed <= Self.claudeSilentTurnCeiling {
                    continue
                }
                sessions[key]?.status = .idle
                sessions[key]?.currentTool = nil
                sessions[key]?.toolDescription = nil
            }
        }

        // 2b. Some CLIs keep their parent process alive across requests, so a missed Stop hook
        // can leave the UI stuck in bare "thinking" forever after an interrupt. If we've had no
        // follow-up hook activity for a long time and there isn't even a live tool/description,
        // reset that silent processing state back to idle.
        let monitoredThinkingTimeout: TimeInterval = 300
        let nativeAppThinkingTimeout: TimeInterval = 30
        let codexTerminalTurnSettleTime: TimeInterval = 3
        for (key, session) in sessions
            where session.status == .processing
            && session.currentTool == nil
            && session.toolDescription == nil {
            let elapsed = -session.lastActivity.timeIntervalSinceNow
            guard processMonitors[key] != nil else { continue }
            // Claude — CLI or a Claude Desktop Code session, which counts as a
            // native app — goes silent for minutes while it thinks or streams a
            // big Write. Its transcript says whether the turn is still open;
            // the native-app 30s rule below put working sessions to sleep.
            if session.isClaude {
                if elapsed > nativeAppThinkingTimeout,
                   let turn = Self.claudeTranscriptTurn(atPath: session.transcriptPath) {
                    if turn == .ended || elapsed > Self.claudeSilentTurnCeiling {
                        sessions[key]?.status = .idle
                    }
                    continue
                }
            } else if session.isNativeAppMode,
               elapsed >= codexTerminalTurnSettleTime,
               let finishedAt = Self.nativeAppFinishedTurnTimestamp(sessionId: key, session: session),
               finishedAt >= session.lastActivity.addingTimeInterval(-1) {
                sessions[key]?.status = .idle
                continue
            }
            // Native apps write transcripts synchronously — if the transcript check above
            // didn't find a stop marker after 30s, the session is almost certainly idle.
            if session.isNativeAppMode, !session.isClaude, elapsed > nativeAppThinkingTimeout {
                sessions[key]?.status = .idle
                continue
            }
            if elapsed > monitoredThinkingTimeout {
                sessions[key]?.status = .idle
            }
        }

        // 3. Verify PID liveness for sessions without monitors but with a known PID.
        //    If the process died: idle sessions are removed directly (no grace needed),
        //    non-idle sessions go through handleProcessExit for the 5s grace period.
        for (key, session) in sessions where processMonitors[key] == nil {
            guard let process = resolvedSessionProcessIdentity(for: key) else { continue }
            if !Self.isLiveProcess(process) {
                if exitingSessions[key] == process { continue }
                if session.status == .idle {
                    removeSession(key)
                } else {
                    handleProcessExit(sessionId: key, exitedProcess: process)
                }
            }
        }

        // 3b. Native app sessions (OpenCode desktop, Codex app, etc.) whose app is no longer
        //     running should be cleaned up — these apps can't send SessionEnd when force-quit.
        //     Don't check PID liveness here: the dedup in integrateDiscovered may have
        //     reattached a CLI PID to the old native app session, keeping it alive incorrectly.
        // `NSWorkspace.runningApplications` is not a cheap array read: touching
        // `bundleIdentifier` on each entry goes out to LaunchServices over XPC,
        // and this timer fires every 3 seconds forever. Only two things below
        // need it, and on an idle Mac neither does — so build it lazily and, in
        // the common case, never at all (#299).
        var cachedRunningBundleIds: Set<String>?
        func runningBundleIds() -> Set<String> {
            if let cachedRunningBundleIds { return cachedRunningBundleIds }
            let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            cachedRunningBundleIds = ids
            return ids
        }

        if sessions.values.contains(where: { $0.isNativeAppMode }) {
            let running = runningBundleIds()
            for (key, session) in sessions {
                guard session.isNativeAppMode,
                      let bundleId = session.termBundleId,
                      !running.contains(bundleId) else { continue }
                removeSession(key)
            }
        }
        let discoveryPollNow = Date()
        // Check the cheap clock predicate before the expensive app list: the poll
        // is rate-limited to every 6s, so five of every six ticks can skip it.
        let codexPollIntervalElapsed = lastCodexDesktopDiscoveryPollAt.map {
            discoveryPollNow.timeIntervalSince($0) >= 6
        } ?? true
        if codexPollIntervalElapsed, Self.shouldPollCodexDesktopDiscovery(
            runningBundleIdentifiers: runningBundleIds(),
            lastPollAt: lastCodexDesktopDiscoveryPollAt,
            now: discoveryPollNow
        ) {
            lastCodexDesktopDiscoveryPollAt = discoveryPollNow
            requestCodexDesktopDiscoveryScan()
        }

        // 4. Remove finished conversations the den has shown, a little after.
        for (key, session) in sessions where session.status == .idle {
            if Self.isStaleIdleSession(lastActivity: session.lastActivity, seenAt: idleSeenAt[key]) {
                removeSession(key)
            }
        }

        // 5. Reclaim memory for abandoned tool_use_id cache entries.
        prunePendingToolUses()

        refreshDerivedState()
    }

    private nonisolated static func currentPluginSessionMode() -> String {
        UserDefaults.standard.string(forKey: SettingsKey.pluginSessionMode)
            ?? SettingsDefaults.pluginSessionMode
    }

    // MARK: - Process Monitoring (DispatchSource)

    private func currentSessionProcessIdentity(for sessionId: String) -> ProcessIdentity? {
        guard let pid = sessions[sessionId]?.cliPid, pid > 0 else { return nil }
        return ProcessIdentity(pid: pid, startTime: sessions[sessionId]?.cliStartTime)
    }

    private func resolvedSessionProcessIdentity(for sessionId: String) -> ProcessIdentity? {
        guard let process = currentSessionProcessIdentity(for: sessionId) else { return nil }
        if let resolved = Self.trackedProcessIdentity(for: process.pid, source: sessions[sessionId]?.source) {
            if resolved != process {
                setSessionProcessIdentity(resolved, for: sessionId)
            }
            return resolved
        }
        if process.startTime != nil { return process }
        guard let refreshed = Self.liveProcessIdentity(for: process.pid) else { return process }
        setSessionProcessIdentity(refreshed, for: sessionId)
        return refreshed
    }

    private func setSessionProcessIdentity(_ process: ProcessIdentity, for sessionId: String) {
        sessions[sessionId]?.cliPid = process.pid
        sessions[sessionId]?.cliStartTime = process.startTime
    }

    private func shouldTerminateOrphanedProcess(sessionId: String, pid: pid_t) -> Bool {
        guard let session = sessions[sessionId] else { return true }
        if session.isNativeAppMode { return false }
        guard let source = SessionSnapshot.normalizedSupportedSource(session.source) else { return true }
        return !Self.isNativeAppProcess(pid, source: source)
    }

    /// Current ppid of `pid`, or nil if the process is gone / info is unavailable.
    nonisolated static func parentPid(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard ret > 0 else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// A process counts as a terminal orphan only when it USED to have a real parent
    /// (attachParentPid > 1) and has since been reparented to launchd/init (ppid <= 1).
    /// Daemons started by launchd have ppid <= 1 from the beginning and are never
    /// orphans, no matter how long they run (#243). Unknown attach ppid stays safe: no kill.
    nonisolated static func isReparentedOrphan(currentParentPid: pid_t?, attachParentPid: pid_t?) -> Bool {
        guard let currentParentPid, currentParentPid <= 1 else { return false }
        guard let attachParentPid, attachParentPid > 1 else { return false }
        return true
    }

    nonisolated static func liveProcessIdentity(for pid: pid_t) -> ProcessIdentity? {
        guard pid > 0, kill(pid, 0) == 0 else { return nil }
        return ProcessIdentity(pid: pid, startTime: getProcessStartTime(pid))
    }

    nonisolated static func isLiveProcess(_ process: ProcessIdentity) -> Bool {
        guard process.pid > 0, kill(process.pid, 0) == 0 else { return false }
        guard let expectedStart = process.startTime else { return true }
        return getProcessStartTime(process.pid) == expectedStart
    }

    private nonisolated static func trackedProcessIdentity(for pid: pid_t, source: String?) -> ProcessIdentity? {
        guard pid > 0 else { return nil }

        var currentPid: pid_t? = pid
        var visited = Set<pid_t>()
        var firstLiveProcess: ProcessIdentity?

        for _ in 0..<6 {
            guard let candidatePid = currentPid,
                  candidatePid > 0,
                  !visited.contains(candidatePid),
                  let process = liveProcessIdentity(for: candidatePid) else {
                break
            }

            visited.insert(candidatePid)
            if firstLiveProcess == nil {
                firstLiveProcess = process
            }
            if let path = executablePath(for: candidatePid),
               CLIProcessResolver.sourceMatchesExecutablePath(path, source: source) {
                return process
            }
            currentPid = parentPID(for: candidatePid)
        }

        return firstLiveProcess
    }

    private nonisolated static func parentPID(for pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard ret > 0, info.pbi_ppid > 0 else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private nonisolated static func isNativeAppProcess(_ pid: pid_t, source: String) -> Bool {
        guard let executable = executablePath(for: pid) else { return false }
        let path = executable.lowercased()
        switch source {
        case "codex":      return isCodexExecutablePath(executable)
        case "opencode":   return path.contains("/opencode.app/contents/")
        // Google Antigravity IDE — host app is Antigravity.app.
        case "google-antigravity": return path.contains("/antigravity.app/contents/")
        // Claude Code Desktop (#211): local Code-tab sessions live inside Claude.app.
        case "claude":      return path.contains("/claude.app/contents/")
        default:           return false
        }
    }

    /// Watch a Claude process for exit — waits a grace period before removing, in case the
    /// process restarts (e.g. auto-update) or a new hook event re-activates the session.
    private func monitorProcess(sessionId: String, pid: pid_t) {
        guard let process = Self.liveProcessIdentity(for: pid) else {
            handleProcessExit(sessionId: sessionId, exitedProcess: ProcessIdentity(pid: pid, startTime: nil))
            return
        }
        monitorProcess(sessionId: sessionId, process: process)
    }

    private func monitorProcess(sessionId: String, process: ProcessIdentity) {
        guard processMonitors[sessionId] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: process.pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self = self, self.sessions[sessionId] != nil else { return }
                self.handleProcessExit(sessionId: sessionId, exitedProcess: process)
            }
        }
        source.resume()
        processMonitors[sessionId] = (source: source, process: process, attachParentPid: Self.parentPid(of: process.pid))
        exitingSessions.removeValue(forKey: sessionId)

        // Keep cliPid aligned with the monitored process unless we already have a different
        // live PID from a stronger source (hooks beat heuristic discovery).
        if let currentProcess = resolvedSessionProcessIdentity(for: sessionId) {
            if !Self.isLiveProcess(currentProcess) || currentProcess.pid == process.pid {
                setSessionProcessIdentity(process, for: sessionId)
            }
        } else {
            setSessionProcessIdentity(process, for: sessionId)
        }

        // Safety: if process already exited before monitor started
        if !Self.isLiveProcess(process) {
            handleProcessExit(sessionId: sessionId, exitedProcess: process)
        }
    }

    /// Grace period after process exit — gives 5s for a replacement process or fresh hook event
    /// to claim the session before removal. Prevents flicker during agent restarts.
    private func handleProcessExit(sessionId: String, exitedProcess: ProcessIdentity) {
        // Tear down the dead monitor immediately
        stopMonitor(sessionId)

        // If the session already moved to a replacement live PID, reattach immediately and
        // avoid flashing idle because a stale/wrong monitor exited.
        if let currentProcess = resolvedSessionProcessIdentity(for: sessionId),
           currentProcess != exitedProcess, Self.isLiveProcess(currentProcess) {
            monitorProcess(sessionId: sessionId, process: currentProcess)
            return
        }

        if exitingSessions[sessionId] == exitedProcess {
            return
        }
        exitingSessions[sessionId] = exitedProcess

        // If session was actively doing something, reset state right away so the UI
        // doesn't show a stale "running Edit" while we wait through the grace period.
        if let status = sessions[sessionId]?.status, status != .idle {
            sessions[sessionId]?.status = .idle
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
            // Drain any pending permissions/questions — the process is gone
            drainPermissions(forSession: sessionId, reason: "process-exited")
            drainQuestions(forSession: sessionId, reason: "process-exited")
            refreshDerivedState()
        }

        let exitTime = Date()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self = self, self.sessions[sessionId] != nil else { return }
            guard self.exitingSessions[sessionId] == exitedProcess else { return }

            // A new monitor was attached during the grace period (new process took over)
            if self.processMonitors[sessionId] != nil { return }

            // Session was taken over by a different process (e.g. auto-update/restart):
            // cliPid changed to a new PID that's still alive → attach monitor, don't remove.
            if let currentProcess = self.resolvedSessionProcessIdentity(for: sessionId),
               currentProcess != exitedProcess, Self.isLiveProcess(currentProcess) {
                self.monitorProcess(sessionId: sessionId, process: currentProcess)
                return
            }

            // Original process confirmed dead — remove regardless of lastActivity.
            // This prevents a race where an in-flight hook event (e.g. "Stop") updates
            // lastActivity after exitTime, causing the session to linger for 10+ minutes.
            if !Self.isLiveProcess(exitedProcess) {
                self.removeSession(sessionId)
                return
            }

            // Session received fresh activity during the grace period and the original PID is
            // still alive — the exit signal was stale/spurious, so restore monitoring.
            if let lastActivity = self.sessions[sessionId]?.lastActivity,
               lastActivity > exitTime {
                self.monitorProcess(sessionId: sessionId, process: exitedProcess)
                return
            }

            self.removeSession(sessionId)
        }
    }

    private func stopMonitor(_ sessionId: String) {
        processMonitors[sessionId]?.source.cancel()
        processMonitors.removeValue(forKey: sessionId)
    }

    /// Remove a session, clean up its monitor, and resume any pending continuations.
    /// Every removal path (cleanup timer, process exit, reducer effect) goes through here
    /// so leaked continuations / connections are impossible.
    func removeSession(_ sessionId: String) {
        // Resume ALL pending continuations for this session
        drainPermissions(forSession: sessionId, reason: "removeSession")
        drainQuestions(forSession: sessionId, reason: "removeSession")

        completionQueue.removeAll { $0 == sessionId }
        if surface.sessionId == sessionId {
            autoCollapseTask?.cancel()
            if case .completionCard = surface {
                // The turn on this card belongs to a session that is going
                // away: nothing is left on it to read, pointer on it or not.
                completionHasBeenEntered = false
                deferCollapseOnMouseLeave = false
                showNextCompletionOrCollapse()
            } else {
                _ = showNextPending()
            }
        }
        sessions.removeValue(forKey: sessionId)
        stopMonitor(sessionId)
        detachTranscriptTailer(sessionId: sessionId)
        exitingSessions.removeValue(forKey: sessionId)
        idleSeenAt.removeValue(forKey: sessionId)
        modelReadRetryAt.removeValue(forKey: sessionId)
        subagentModelObservations.removeValue(forKey: sessionId)
        subagentModelReads.removeValue(forKey: sessionId)
        if activeSessionId == sessionId {
            activeSessionId = mostActiveSessionId()
        }
        startRotationIfNeeded()
        refreshDerivedState()
        scheduleSave()
    }

    // MARK: - Compact bar mascot rotation

    /// Cached sorted active session IDs — refreshed by refreshActiveIds()
    private var cachedActiveIds: [String] = []

    private func refreshActiveIds() {
        cachedActiveIds = sessions
            .filter { $0.value.status != .idle }
            .sorted { a, b in
                let pa = statusPriority(a.value.status)
                let pb = statusPriority(b.value.status)
                if pa != pb { return pa > pb }
                // Same priority — most recently active first
                return a.value.lastActivity > b.value.lastActivity
            }
            .map(\.key)
    }

    /// Higher = more urgent, shown first in rotation
    private func statusPriority(_ status: AgentStatus) -> Int {
        switch status {
        case .waitingApproval: return 5
        case .waitingQuestion: return 4
        case .running:         return 3
        case .processing:      return 2
        case .idle:            return 0
        }
    }

    private func startRotationIfNeeded() {
        refreshActiveIds()
        if cachedActiveIds.count > 1 {
            // If the most urgent session changed, snap to it immediately
            if let top = cachedActiveIds.first, top != rotatingSessionId {
                let topStatus = sessions[top]?.status ?? .idle
                let currentStatus = rotatingSessionId.flatMap { sessions[$0]?.status } ?? .idle
                if statusPriority(topStatus) > statusPriority(currentStatus) {
                    rotatingSessionId = top
                }
            }
            if rotatingSessionId == nil || !cachedActiveIds.contains(rotatingSessionId!) {
                rotatingSessionId = cachedActiveIds.first
            }
            if rotationTimer == nil {
                let interval = TimeInterval(max(1, SettingsManager.shared.rotationInterval))
                rotationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.rotateToNextSession()
                    }
                }
            }
        } else {
            rotationTimer?.invalidate()
            rotationTimer = nil
            rotatingSessionId = nil
            // When rotation stops, ensure activeSessionId points to the remaining
            // active session (if any) so the collapsed bar doesn't stick on an idle one.
            if let active = cachedActiveIds.first,
               activeSessionId != active {
                activeSessionId = active
            }
        }
    }

    private func rotateToNextSession() {
        guard cachedActiveIds.count > 1 else {
            rotatingSessionId = nil
            return
        }
        if let current = rotatingSessionId, let idx = cachedActiveIds.firstIndex(of: current) {
            rotatingSessionId = cachedActiveIds[(idx + 1) % cachedActiveIds.count]
        } else {
            rotatingSessionId = cachedActiveIds.first
        }
    }

    /// Start monitoring the CLI process for a session.
    /// Prefers the PID captured by the bridge (_ppid), falls back to source-aware process scans by CWD.
    private func tryMonitorSession(_ sessionId: String) {
        // Codex Desktop cards are owned by NSWorkspace/app-server lifecycle. A
        // CWD lookup can only find an unrelated Codex CLI process (or the
        // shared Desktop helper), and binding either PID would remove every
        // Desktop thread when that one process exits. Other native providers
        // keep their existing monitor behavior.
        if sessions[sessionId]?.source == "codex",
           sessions[sessionId]?.termBundleId == Self.codexAppBundleId {
            stopMonitor(sessionId)
            sessions[sessionId]?.cliPid = nil
            sessions[sessionId]?.cliStartTime = nil
            exitingSessions.removeValue(forKey: sessionId)
            return
        }
        let currentMonitor = processMonitors[sessionId]?.process

        // Primary: use PID from bridge (works for any CLI)
        if let sessionProcess = resolvedSessionProcessIdentity(for: sessionId),
           Self.isLiveProcess(sessionProcess) {
            if currentMonitor == sessionProcess { return }
            if currentMonitor != nil {
                stopMonitor(sessionId)
            }
            monitorProcess(sessionId: sessionId, process: sessionProcess)
            return
        }

        if let currentMonitor, Self.isLiveProcess(currentMonitor) {
            setSessionProcessIdentity(currentMonitor, for: sessionId)
            return
        }

        // Fallback: scan for matching processes by CWD (source-aware)
        guard let cwd = sessions[sessionId]?.cwd else { return }
        let source = sessions[sessionId]?.source
        Task.detached {
            let pid = Self.findPidForCwd(cwd, source: source)
            await MainActor.run { [weak self] in
                guard let self = self, let pid = pid,
                      self.sessions[sessionId] != nil else { return }
                guard let discoveredProcess = Self.liveProcessIdentity(for: pid) else { return }

                let preferredProcess: ProcessIdentity
                if let currentProcess = self.resolvedSessionProcessIdentity(for: sessionId),
                   Self.isLiveProcess(currentProcess) {
                    preferredProcess = currentProcess
                } else {
                    preferredProcess = discoveredProcess
                    self.setSessionProcessIdentity(discoveredProcess, for: sessionId)
                }

                if let monitorProcess = self.processMonitors[sessionId]?.process,
                   monitorProcess == preferredProcess, Self.isLiveProcess(monitorProcess) {
                    return
                }

                if self.processMonitors[sessionId] != nil {
                    self.stopMonitor(sessionId)
                }
                self.monitorProcess(sessionId: sessionId, process: preferredProcess)
            }
        }
    }

    /// Find a CLI process PID by matching CWD, scoped to the correct source.
    /// Never guesses across sources: a missing/unknown source returns no PID instead of
    /// accidentally binding a session to the wrong process family.
    private nonisolated static func findPidForCwd(_ cwd: String, source: String? = nil) -> pid_t? {
        guard let normalizedSource = SessionSnapshot.normalizedSupportedSource(source) else { return nil }
        let pids = findPids(forSource: normalizedSource)
        for pid in pids {
            if getCwd(for: pid) == cwd { return pid }
        }
        return nil
    }

    private nonisolated static func findPids(forSource source: String, candidatePids: [pid_t]? = nil) -> [pid_t] {
        switch source {
        case "claude":     return findClaudePids(candidatePids: candidatePids)
        case "codex":      return findCodexPids(candidatePids: candidatePids)
        case "opencode":   return findOpenCodePids(candidatePids: candidatePids)
        case "google-antigravity": return findGoogleAntigravityPids(candidatePids: candidatePids)
        default:           return []
        }
    }

    enum CompletionStyle: String {
        case expand, glance, off
    }

    /// Three-way completion notification style. The completion card is off
    /// by default (the completion sound still plays: it is a separate
    /// effect). Never set or unknown → .off; that includes the pre-glance
    /// boolean `autoExpandOnCompletion` (#146), whose false already meant off.
    nonisolated static func completionStyle(defaults: UserDefaults = .standard) -> CompletionStyle {
        if let raw = defaults.string(forKey: SettingsKey.completionNotificationStyle),
           let style = CompletionStyle(rawValue: raw) {
            return style
        }
        return .off
    }

    /// `turnFailed`: the turn ended on an error (StopFailure).
    func enqueueCompletion(_ sessionId: String, turnFailed: Bool = false) {
        // The session card reads ERROR until the next prompt.
        sessions[sessionId]?.lastTurnFailed = turnFailed
        turnDoneAt[sessionId] = turnFailed ? nil : Date()
        PetReactionCenter.shared.turnEnded(sessionId: sessionId, failed: turnFailed)
        switch Self.completionStyle() {
        case .off:
            // Panel stays compact — status indicators still update, but no
            // completion card pops down (#146).
            return
        case .glance:
            flashGlanceCompletionIndicator()
            return
        case .expand:
            break
        }

        // Don't queue duplicates
        if completionQueue.contains(sessionId) || justCompletedSessionId == sessionId { return }

        if isShowingCompletion || isShowingInteractive {
            // Already showing one — queue this for later
            completionQueue.append(sessionId)
        } else {
            // Show immediately
            showCompletion(sessionId)
        }
    }

    /// Last unresolved-branch probe per session — keeps `gitBranch == nil`
    /// (non-repo cwds, SessionStart snapshot rebuilds) from probing on every event.
    private var gitBranchCheckedAt: [String: Date] = [:]

    /// Branch resolution runs detached: .git probing on a dead network mount
    /// must never beachball the main actor. Triggers on cwd changes, at Stop
    /// (the turn may have switched branches), and while unresolved (throttled).
    private func maybeRefreshGitBranch(for sessionId: String, cwdBefore: String?, normalizedEventName: String) {
        guard let session = sessions[sessionId],
              let cwd = session.cwd else { return }
        let unresolvedDue = session.gitBranch == nil
            && Date().timeIntervalSince(gitBranchCheckedAt[sessionId] ?? .distantPast) > 60
        guard cwd != cwdBefore || normalizedEventName == "Stop" || unresolvedDue else { return }
        gitBranchCheckedAt[sessionId] = Date()
        Task.detached(priority: .utility) {
            let info = GitBranchReader.read(cwd: cwd)
            await MainActor.run { [weak self] in
                guard let self, var s = self.sessions[sessionId], s.cwd == cwd else { return }
                s.gitBranch = info?.branch
                s.gitIsWorktree = info?.isWorktree ?? false
                self.sessions[sessionId] = s
            }
        }
    }

    private func flashGlanceCompletionIndicator() {
        guard !surface.isExpanded else { return }  // user is already looking
        glanceCompletionActive = true
        glanceDismissTask?.cancel()
        glanceDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            guard !Task.isCancelled else { return }
            glanceCompletionActive = false
        }
    }

    /// Fast app-level suppress check (main-thread safe, no blocking).
    private func shouldSuppressAppLevel(for sessionId: String) -> Bool {
        !shouldAutoOpenPendingSurface(for: sessionId)
    }

    /// Notification kinds that describe the *account*, not the conversation.
    /// CodeBuddy's documented `notification_type` set is `permission_prompt`,
    /// `idle_prompt`, `auth_success`; only the last is boot-time auth chatter,
    /// and it arrives before `SessionStart` with its own session id. Matching by
    /// prefix so a future `auth_failed`/`auth_expired` behaves the same. (#288)
    nonisolated static func isAccountNotification(_ event: HookEvent) -> Bool {
        guard let kind = notificationKind(from: event) else { return false }
        return kind.hasPrefix("auth")
    }

    /// Whether a permission request may expand the island on its own. Smart
    /// Suppress only covers "the agent's own terminal is in front"; users who
    /// work in a *different* app still got the panel thrown in their face on
    /// every approval. With this off the sound and the session-list badge still
    /// fire and the card is one click away, but focus is never stolen. (#292)
    static func autoExpandOnPermission(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: SettingsKey.autoExpandOnPermission) != nil else {
            return SettingsDefaults.autoExpandOnPermission
        }
        return defaults.bool(forKey: SettingsKey.autoExpandOnPermission)
    }

    /// The question counterpart of `autoExpandOnPermission`. Questions never
    /// honoured that switch — an AskUserQuestion card opened even when the
    /// user had asked the island not to steal focus. With this off the sound
    /// still plays, the collapsed bar shows a question badge, and one click
    /// (on the bar, or "Answer" in the session list) opens the card.
    static func autoExpandOnQuestion(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: SettingsKey.autoExpandOnQuestion) != nil else {
            return SettingsDefaults.autoExpandOnQuestion
        }
        return defaults.bool(forKey: SettingsKey.autoExpandOnQuestion)
    }

    /// Session of a queued question the island is not showing — what the
    /// collapsed bar's question badge advertises and a click opens.
    var hiddenPendingQuestionSessionId: String? {
        // A question still waiting to be seen comes before one the user closed.
        guard let head = nextVisibleQuestion ?? questionQueue.first else { return nil }
        if case .questionCard = surface { return nil }
        return head.event.sessionId ?? "default"
    }

    /// Open the card for a pending question on an explicit user action (a click
    /// on the collapsed bar, "Answer" in the session list). Never gated by
    /// auto-expand or Smart Suppress: those only decide what opens *by itself*.
    func openPendingQuestionCard(sessionId: String? = nil) {
        guard let sid = sessionId ?? hiddenPendingQuestionSessionId,
              let request = pendingQuestion(forSession: sid) else { return }
        // Opening it again takes back a close: it is on screen, so it may
        // stay up and remind like any other waiting question.
        dismissedQuestionIds.remove(request.id)
        activeSessionId = sid
        withAnimation(NotchAnimation.open) {
            surface = .questionCard(sessionId: sid)
        }
    }

    /// Open a waiting approval's card on an explicit user action (its den
    /// row, a click on its lit pet). Opening it again takes back a dismiss,
    /// as `openPendingQuestionCard` takes back a close: otherwise the next
    /// re-evaluation folds the card as dismissed, and a shortcut pressed on
    /// it closes it instead of answering.
    func reopenPermissionCard(sessionId: String) {
        guard pendingPermission(forSession: sessionId) != nil else { return }
        dismissedPermissionSessionIds.remove(sessionId)
        activeSessionId = sessionId
        withAnimation(NotchAnimation.open) {
            surface = .approvalCard(sessionId: sessionId)
        }
    }

    func shouldAutoOpenPendingSurface(
        for sessionId: String,
        isTerminalFrontmost: (SessionSnapshot) -> Bool = TerminalVisibilityDetector.isTerminalFrontmostForSession
    ) -> Bool {
        guard UserDefaults.standard.bool(forKey: SettingsKey.smartSuppress) else { return true }
        guard let session = sessions[sessionId],
              (session.termApp != nil || session.termBundleId != nil) else { return true }
        return !isTerminalFrontmost(session)
    }

    /// Smart Suppress for a question: may its card open by itself, as far as
    /// "is the user already looking at the agent" goes? The "auto-expand on
    /// question" switch is a separate, UI-only choice checked where the card
    /// opens; folded in here, it read as "the user is looking" to anything
    /// else that asked (the AskUserQuestion push once did).
    private func shouldAutoOpenQuestionSurface(for event: HookEvent) -> Bool {
        // Claude Desktop draws the same question in its own conversation while
        // the hook waits; answering there ends the hook and drains the card,
        // so it races like any approval and Smart Suppress applies.
        let hostDrawsAsk = sessions[event.sessionId ?? "default"].map { $0.isClaude && $0.isNativeAppMode } ?? false
        if event.toolName == "AskUserQuestion", !hostDrawsAsk {
            return true
        }
        return shouldAutoOpenPendingSurface(
            for: event.sessionId ?? "default",
            isTerminalFrontmost: questionTerminalFrontmostDetector
        )
    }

    private func showCompletion(_ sessionId: String) {
        // Fast path: terminal not even frontmost — show immediately
        guard shouldSuppressAppLevel(for: sessionId) else {
            doShowCompletion(sessionId)
            return
        }

        // Terminal IS frontmost — check tab-level on background thread
        guard let session = sessions[sessionId] else { return }
        let sessionCopy = session
        Task.detached {
            let tabVisible = TerminalVisibilityDetector.isSessionTabVisible(sessionCopy)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Verify state hasn't changed while we were checking
                // (e.g. approval/question card popped up, session was removed)
                guard self.sessions[sessionId] != nil else { return }
                switch self.surface {
                case .approvalCard, .questionCard: return  // don't overwrite higher-priority surfaces
                default: break
                }
                if !tabVisible {
                    withAnimation(NotchAnimation.pop) {
                        self.doShowCompletion(sessionId)
                    }
                }
            }
        }
    }

    private func doShowCompletion(_ sessionId: String) {
        activeSessionId = sessionId
        surface = .completionCard(sessionId: sessionId)
        completionHasBeenEntered = false
        deferCollapseOnMouseLeave = false

        autoCollapseTask?.cancel()
        let delay = completionAutoCollapseDelay
        autoCollapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            showNextCompletionOrCollapse()
        }
    }

    /// How long a completion card whose time is already up stays after the
    /// pointer leaves it, so a pointer drifting off the edge can come back.
    @ObservationIgnored
    var completionLeaveGrace: TimeInterval = 1.5

    /// The pointer left the completion card. A pointer passing over it on the
    /// way to the menu bar must not cut the card short: it keeps the rest of
    /// its time, and if that is already over it folds a moment later. "Got it"
    /// on the card still closes it at once.
    func completionPointerLeft() {
        guard isShowingCompletion else { return }
        completionHasBeenEntered = false
        guard deferCollapseOnMouseLeave else { return }  // its own timer is still running
        deferCollapseOnMouseLeave = false
        autoCollapseTask?.cancel()
        let grace = completionLeaveGrace
        autoCollapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard !Task.isCancelled else { return }
            showNextCompletionOrCollapse()
        }
    }

    func cancelCompletionQueue() {
        autoCollapseTask?.cancel()
        completionQueue.removeAll()
        deferCollapseOnMouseLeave = false
    }

    private func showNextCompletionOrCollapse() {
        // Once the mouse has entered the completion card, defer collapse until it leaves
        if completionHasBeenEntered {
            deferCollapseOnMouseLeave = true
            return
        }
        // Interactive items first, then the next finished turn, then collapse.
        if showNextPending() || showNextQueuedCompletion() { return }
        withAnimation(NotchAnimation.close) {
            surface = .collapsed
        }
    }

    // Cached derived state (refreshed by refreshDerivedState after session mutations)
    private(set) var status: AgentStatus = .idle
    private(set) var primarySource: String = "claude"
    private(set) var activeSessionCount: Int = 0
    private(set) var totalSessionCount: Int = 0

    var currentTool: String? {
        // When approvals/questions are pending, always reflect the *front of the queue*.
        // Otherwise a second incoming request can overwrite session.currentTool and make
        // the first pending item appear to “disappear” in compact UI.
        if let pending = pendingPermission {
            return pending.event.toolName
        }
        if pendingQuestion != nil {
            // AskUserQuestion arrives via PermissionRequest tool.
            return "AskUserQuestion"
        }
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.currentTool
    }

    var toolDescription: String? {
        if let pending = pendingPermission {
            let sessionId = pending.event.sessionId ?? activeSessionId ?? "default"
            return pending.event.toolDescription ?? sessions[sessionId]?.toolDescription
        }
        if let q = pendingQuestion {
            return q.question.question
        }
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.toolDescription
    }

    var activeDisplayName: String? {
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        let displaySessionId = s.displaySessionId(sessionId: id)
        return s.displayTitle(sessionId: displaySessionId)
    }

    var activeModel: String? {
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.model
    }

    /// Recompute cached status/source/counts from sessions in a single O(n) pass.
    /// Call after any mutation to `sessions` or session status.
    func refreshDerivedState() {
        let summary = deriveSessionSummary(from: sessions)
        // Whenever no session is actively working, honor the user-configured
        // default mascot. Covers both "no sessions at all" (#102) and "all
        // sessions idle" (#149) — without this, a user who sets the default
        // to Codex still sees Claude every time their last session goes idle
        // because deriveSessionSummary echoes the most recently active source.
        // Active work always wins (running / processing / waiting* status).
        let effectiveSource: String
        if summary.status == .idle {
            effectiveSource = SettingsManager.shared.defaultSource
        } else {
            effectiveSource = summary.primarySource
        }
        // Only assign when changed (avoids unnecessary @Observable notifications)
        if status != summary.status { status = summary.status }
        if primarySource != effectiveSource { primarySource = effectiveSource }
        if activeSessionCount != summary.activeSessionCount { activeSessionCount = summary.activeSessionCount }
        if totalSessionCount != summary.totalSessionCount { totalSessionCount = summary.totalSessionCount }
    }

    private func refreshProviderTitle(for trackedSessionId: String, providerSessionId: String? = nil) {
        guard let session = sessions[trackedSessionId] else { return }

        let lookupSessionId = providerSessionId ?? session.providerSessionId ?? trackedSessionId
        if let providerSessionId {
            sessions[trackedSessionId]?.providerSessionId = providerSessionId
        } else if SessionTitleStore.supports(provider: session.source) {
            sessions[trackedSessionId]?.providerSessionId = lookupSessionId
        }

        guard SessionTitleStore.supports(provider: session.source) else { return }

        if let resolved = SessionTitleStore.title(for: lookupSessionId, provider: session.source, cwd: session.cwd,
                                                  claudeDesktopSessionId: session.claudeDesktopSessionId) {
            sessions[trackedSessionId]?.sessionTitle = resolved.title
            sessions[trackedSessionId]?.sessionTitleSource = resolved.source
        } else {
            sessions[trackedSessionId]?.sessionTitle = nil
            sessions[trackedSessionId]?.sessionTitleSource = nil
        }
    }

    func handleEvent(_ event: HookEvent) {
        // Skip events from subagent worktrees — tracked via parent's SubagentStart/Stop
        if let cwd = event.rawJSON["cwd"] as? String,
           cwd.contains("/.claude/worktrees/agent-") || cwd.contains("/.git/worktrees/agent-") {
            return
        }

        let source = event.rawJSON["_source"] as? String
        let hasTranscriptPath = (event.rawJSON["transcript_path"] as? String)
            .map { !$0.isEmpty } ?? false
        if Self.isCodexPlaceholderHook(
            source: source,
            cwd: event.rawJSON["cwd"] as? String,
            hasTranscriptPath: hasTranscriptPath
        ) {
            return
        }

        let sessionId = event.sessionId ?? "default"
        let normalizedEventName = EventNormalizer.normalize(event.eventName)

        // Account chatter, not session activity. CodeBuddy fires
        // Notification(auth_success) as the CLI boots — before SessionStart and
        // under a different session id — which minted a second card that then
        // never updated (#288).
        if normalizedEventName == "Notification",
           Self.isAccountNotification(event) {
            return
        }

        if source?.lowercased() == "codex",
           event.rawJSON["_term_bundle"] as? String == Self.codexAppBundleId,
           let rawProviderSessionId = event.rawJSON["session_id"] as? String {
            let providerSessionId = rawProviderSessionId.hasPrefix(Self.codexAppSessionPrefix)
                ? String(rawProviderSessionId.dropFirst(Self.codexAppSessionPrefix.count))
                : rawProviderSessionId
            if closedCodexAppThreads[providerSessionId] != nil {
                // Tool/notification/terminal hooks can trail app-server
                // `thread/closed`. Only explicit generation-start activity may
                // reopen; `thread/started` clears the same tombstone directly.
                if normalizedEventName == "SessionStart"
                    || normalizedEventName == "UserPromptSubmit" {
                    closedCodexAppThreads.removeValue(forKey: providerSessionId)
                } else {
                    return
                }
            }
        }

        // Skip Codex APP internal sessions (title generation, etc.) — they have no transcript
        if (event.rawJSON["_source"] as? String) == "codex"
            && sessions[sessionId] == nil
            && event.rawJSON["transcript_path"] is NSNull {
            return
        }

        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }

        let prevStatus = sessions[sessionId]?.status
        let wasWaiting = prevStatus == .waitingApproval || prevStatus == .waitingQuestion
        let cwdBeforeReduce = sessions[sessionId]?.cwd

        // Cache PreToolUse payloads so downstream events sharing tool_use_id can be
        // correlated, and drain queue entries whose agent already moved on.
        cachePreToolUseIfApplicable(event)
        resolveToolUseIfCompleted(event)
        // #216: permission requests with no correlatable tool_use_id can't be drained by
        // resolveToolUseIfCompleted. A follow-up activity event means the user already
        // approved in the terminal — resume those (and only those) as approved.
        resolveOrphanPermissionsOnActivity(event)

        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: maxHistory,
                                  replyCompletePlaceholder: L10n.shared["reply_complete_placeholder"])

        maybeRefreshGitBranch(for: sessionId, cwdBefore: cwdBeforeReduce, normalizedEventName: normalizedEventName)

        // Backfill model after metadata extraction. Hooks are inconsistent across providers,
        // so retry with a cooldown instead of giving up permanently on the first miss.
        maybeBackfillModel(for: sessionId)
        if let agentId = event.agentId {
            maybeBackfillSubagentModel(sessionId: sessionId, agentId: agentId, event: event)
        }

        // Session was waiting and got an activity event. Historically we'd
        // blanket-drain the whole queue here, assuming the user answered in the
        // terminal. That heuristic misfires for parallel MCP / plugin tool calls:
        // an unrelated PostToolUse / Stop / etc. would deny pending permissions
        // for *other* in-flight tools (#147).
        //
        // The right signal that a specific permission is moot is its tool_use_id
        // showing up in PostToolUse / PostToolUseFailure / PermissionDenied —
        // resolveToolUseIfCompleted already does that surgically above. We keep
        // the question-queue drain (questions don't carry tool_use_id reliably
        // and are rare enough that a blanket sweep is acceptable) and refresh
        // session status, but never drain unrelated permission requests.
        //
        // The sweep only covers questions asked by the same agent as the event.
        // Background subagents share the parent's session_id, so their tool
        // calls and SubagentStop kept arriving while the main thread's question
        // was on screen and denied it ("Permission denied by hook").
        if wasWaiting {
            let keepWaiting: Set<String> = ["Notification", "SessionStart", "SessionEnd", "PreCompact"]
            if !keepWaiting.contains(normalizedEventName) {
                drainQuestions(
                    forSession: sessionId,
                    reason: "wasWaiting-blanket-drain-event=\(normalizedEventName)",
                    where: { $0.agentId == event.agentId }
                )
                let stillHasPermission = permissionQueue.contains { $0.event.sessionId == sessionId }
                let stillHasQuestion = questionQueue.contains { $0.event.sessionId == sessionId }
                if !stillHasPermission && !stillHasQuestion,
                   sessions[sessionId]?.status == .waitingApproval
                    || sessions[sessionId]?.status == .waitingQuestion {
                    sessions[sessionId]?.status = (normalizedEventName == "Stop") ? .idle : .processing
                    sessions[sessionId]?.currentTool = nil
                    sessions[sessionId]?.toolDescription = nil
                }
                showNextPending()
            }
        }

        // The normalizer folds StopFailure onto Stop; only the raw name says
        // the turn died (same rule as its sound).
        let turnFailed = EventSoundRouting.soundEvent(
            rawEventName: event.eventName, normalizedEventName: normalizedEventName
        ) == EventSoundRouting.turnFailed
        for effect in effects {
            executeEffect(effect, sessionId: sessionId, turnFailed: turnFailed)
        }

        if let provider = sessions[sessionId]?.source,
           SessionTitleStore.supports(provider: provider) {
            refreshProviderTitle(for: sessionId)
        }

        // If a hook just supplied (or changed) this session's transcript path, attach
        // the tailer so the next assistant append shows up in the panel immediately.
        attachTranscriptTailerIfNeeded(sessionId: sessionId)

        // Handle the "else if activeSessionId == sessionId → mostActive" edge case
        // (reducer can't check activeSessionId since it's AppState-local)
        if sessions[sessionId]?.status == .idle && activeSessionId == sessionId {
            if normalizedEventName != "Stop" {
                activeSessionId = mostActiveSessionId()
            }
        }

        // A terminal permission prompt announced by a Notification waits
        // display-only until the next activity event clears it.

        scheduleSave()
        startRotationIfNeeded()
        refreshDerivedState()
    }

    private func executeEffect(_ effect: SideEffect, sessionId: String, turnFailed: Bool = false) {
        switch effect {
        case .playSound(let eventName):
            SoundManager.shared.handleEvent(eventName, sessionId: sessionId, source: sessions[sessionId]?.mascotSource)
        case .tryMonitorSession(let sid):
            tryMonitorSession(sid)
        case .stopMonitor(let sid):
            stopMonitor(sid)
        case .removeSession(let sid):
            removeSession(sid)
        case .enqueueCompletion(let sid):
            enqueueCompletion(sid, turnFailed: turnFailed)
        case .setActiveSession(let sid):
            activeSessionId = sid
        }
    }

    private func maybeBackfillModel(for sessionId: String) {
        guard let session = sessions[sessionId], session.model == nil else { return }
        let now = Date()
        if let retryAt = modelReadRetryAt[sessionId], retryAt > now {
            return
        }

        if let model = Self.readModelForSession(sessionId: sessionId, session: session) {
            sessions[sessionId]?.model = model
            modelReadRetryAt.removeValue(forKey: sessionId)
        } else {
            modelReadRetryAt[sessionId] = now.addingTimeInterval(5)
        }
    }

    func handlePermissionRequest(_ event: HookEvent, continuation: CheckedContinuation<Data, Never>) {
        let sessionId = event.sessionId ?? "default"
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }
        // Extract metadata so blocking-first parent sessions have cwd/source/PID.
        // Subagent events are routed through the parent session ID; their full metadata
        // can describe the child session and should not overwrite the parent — only fill gaps.
        if event.agentId == nil {
            extractMetadata(into: &sessions, sessionId: sessionId, event: event)
        } else {
            fillMissingParentMetadataFromSubagentEvent(into: &sessions, sessionId: sessionId, event: event)
        }
        tryMonitorSession(sessionId)

        // Closed Task/subagent ids must not surface new permission UI (parity with
        // ensureSubagent refusing late tool hooks after Stop).
        if shouldSuppressClosedSubagentUI(sessionId: sessionId, agentId: event.agentId) {
            let denyResponse = Data(
                #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8
            )
            continuation.resume(returning: denyResponse)
            return
        }

        // Clear any pending questions from THIS agent (mutually exclusive within an agent;
        // a background subagent's request must not deny the main thread's question)
        drainQuestions(forSession: sessionId, reason: "newPermissionRequest", where: { $0.agentId == event.agentId })

        sessions[sessionId]?.status = .waitingApproval
        sessions[sessionId]?.currentTool = event.activityLabel
        sessions[sessionId]?.toolDescription = event.toolDescription
        sessions[sessionId]?.lastActivity = Date()
        markMergedSubagentWaiting(sessionId: sessionId, agentId: event.agentId, status: .waitingApproval)
        // Backfill tool name/description from cached PreToolUse when the payload is thin.
        enrichPermissionRequestFromCache(sessionId: sessionId, event: event)

        let request = PermissionRequest(event: event, continuation: continuation)

        // Replay deduplication: if the same tool_use_id is already queued, swap the
        // continuation in place and deny the previous waiter. Preserves card order.
        if mergeDuplicatePermissionRequest(request) {
            refreshDerivedState()
            return
        }

        // A genuinely new request means this session needs a user decision again,
        // so it stops being dismissed. This must come AFTER the replay-dedup
        // return above: a replay is the same decision arriving twice, not a new
        // one, and un-dismissing on a replay resurrects the request the user
        // hid — which then takes the card the arriving session should have got
        // and, counting as a burst already in progress, silences its sound too.
        // (A same-id request with different tool inputs is a distinct request,
        // not a replay — merge returns false for those, so they still land here.)
        dismissedPermissionSessionIds.remove(sessionId)

        // Dismissing hides a request but deliberately leaves it queued, so the
        // CLI stays blocked and the prompt stays recoverable. Gating on
        // `permissionQueue.count == 1` therefore swallowed every later request —
        // from any session — for as long as a dismissed one sat in the queue.
        //
        // The gate's real question is "is an approval card on screen", so ask
        // the surface. Queue-derived proxies do not survive the un-dismiss
        // above: a session's own next request clears its dismissal, which makes
        // its still-queued earlier request count as visible again while nothing
        // is displayed — silencing every later request all over again. (#309)
        //
        // ponytail: a card suppressed by Smart Suppress also leaves a visible
        // request undisplayed, so a second session's request still waits behind
        // it. That is pre-existing (`main` behaves the same) and needs
        // showNextPending to skip un-openable entries; tracked separately.
        //
        // The surface alone is not enough either: `drainPermissions` empties one
        // SESSION's requests without clearing `surface`, so a card can be left
        // pointing at a session that has nothing queued. Ask per session, not
        // per queue — a whole-queue test (`!permissionQueue.isEmpty`) reads as
        // "a card is up" whenever some other session is still waiting, which
        // leaves the panel showing a card for a session with no pending request
        // while later requests queue silently behind it.
        let approvalCardOnScreen: Bool
        if case .approvalCard(let shownSessionId) = surface,
           permissionQueue.contains(where: { ($0.event.sessionId ?? "default") == shownSessionId }) {
            approvalCardOnScreen = true
        } else {
            approvalCardOnScreen = false
        }

        // Card and sound answer different questions and must not share a gate.
        // The sound marks the start of a burst of approvals, which is what
        // `count == 1` used to approximate; within a burst it stays quiet, and
        // a dismissed request sitting in the queue must not count as a burst
        // already in progress.
        let burstAlreadyInProgress = nextVisiblePermissionIndex() != nil
        permissionQueue.append(request)
        PetReactionCenter.shared.permissionAsked(requestId: request.id)

        // Show UI only when no approval card is already up to be stolen from.
        // showNextPending picks the first *visible* request, promotes it to the
        // head and applies the session-list / Smart Suppress rules — pointing
        // the card at this session by hand would show the dismissed request's
        // content whenever a dismissed entry still leads the queue.
        if !approvalCardOnScreen {
            showNextPending()
        }
        if !burstAlreadyInProgress {
            SoundManager.shared.handleEvent("PermissionRequest", sessionId: sessionId, source: sessions[sessionId]?.mascotSource)
        }
        refreshDerivedState()
    }

    /// Index of the queued request the user actually acted on.
    ///
    /// The card on screen is identified by its session, but the answer used to
    /// be applied to `queue.removeFirst()`. Anything that mutates the head
    /// while a card is open — a peer disconnect draining another session, a
    /// stale tool-use eviction, the reorder in `showNextPending()` — would then
    /// resolve whichever request happened to be first, delivering the answer to
    /// the wrong CLI. Callers that know which session the card belongs to pass
    /// it in; `nil` keeps the head-of-queue behaviour for callers that only
    /// ever act on the head. (#308)
    private func permissionIndex(expecting expected: String?) -> Int? {
        guard let expected else { return permissionQueue.isEmpty ? nil : 0 }
        return permissionQueue.firstIndex { ($0.event.sessionId ?? "default") == expected }
    }

    /// Question-queue counterpart of `permissionIndex(expecting:)`. (#308)
    private func questionIndex(expecting expected: String?) -> Int? {
        guard let expected else { return questionQueue.isEmpty ? nil : 0 }
        return questionQueue.firstIndex { ($0.event.sessionId ?? "default") == expected }
    }

    /// The request the card was showing is no longer queued (answered in the
    /// terminal, drained on disconnect). `showNextPending()` drops the dead card
    /// and re-opens whatever is genuinely waiting. (#308)
    private func discardStalePanelAction(expected: String, kind: String) {
        log.notice("⚠️ ignored \(kind, privacy: .public) for session=\(expected, privacy: .public) — request no longer queued")
        showNextPending()
        refreshDerivedState()
    }

    func approvePermission(always: Bool = false, expectedSessionId: String? = nil) {
        guard let index = permissionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "approve")
            }
            return
        }
        let pending = permissionQueue.remove(at: index)
        let sessionId = pending.event.sessionId ?? "default"
        PetReactionCenter.shared.permissionApproved(requestId: pending.id, sessionId: sessionId)
        dismissedPermissionSessionIds.remove(sessionId)
        let responseData: Data
        if always, CodexPermissionRules.isCodexEvent(pending.event) {
            _ = CodexPermissionRules().persistAlwaysAllowRule(for: pending.event)
            let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
            responseData = Data(response.utf8)
        } else if always {
            let toolName = pending.event.toolName ?? ""
            // MCP tools (`mcp__server__tool`) don't accept a rule specifier — the
            // rule must be the bare tool name. Sending `ruleContent: "*"` makes
            // Claude Code assemble `mcp__server__tool(*)`, which never matches an
            // actual MCP call, so the "always allow" rule silently fails to
            // persist and the same approval keeps re-prompting. Non-MCP tools
            // (Bash/Read/Edit/…) keep the `*` specifier. (#224)
            var rule: [String: Any] = ["toolName": toolName]
            if !toolName.hasPrefix("mcp__") {
                rule["ruleContent"] = "*"
            }
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedPermissions": [[
                            "type": "addRules",
                            "rules": [rule],
                            "behavior": "allow",
                            "destination": "session"
                        ]]
                    ] as [String: Any]
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        } else {
            let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
            responseData = Data(response.utf8)
        }
        pending.continuation.resume(returning: responseData)
        resolveMergedSubagentAfterUI(
            sessionId: sessionId,
            agentId: pending.event.agentId,
            subagentStatus: .running,
            keepSubagentTool: pending.event.toolName,
            idleParentWhenNoAgent: false
        )

        showNextPending()
        refreshDerivedState()
    }

    /// Find an existing session whose source matches and whose CLI PID equals
    /// the supplied ppid. Used by HookServer to merge plugin-proxied events
    /// (e.g. omo) into their main session when pluginSessionMode == "merge". (#123)
    ///
    /// We additionally require the candidate session to have been active in
    /// the last 5 minutes. This guards against macOS PID reuse — a stale
    /// session whose CLI long since exited could otherwise still match the
    /// plugin event's `_ppid` if the OS recycled that PID for an unrelated
    /// process. Live sessions update `lastActivity` on every event so the
    /// window is generous; stale ones get skipped. (#123 review)
    func findSessionId(
        forSource source: String,
        ppid: Int,
        excluding excludedSessionId: String? = nil,
        requireActive: Bool = false
    ) -> String? {
        let normalized = SessionSnapshot.normalizedSupportedSource(source)
        let cutoff = Date().addingTimeInterval(-300)
        return sessions
            .filter { sessionId, snap in
                let snapSource = SessionSnapshot.normalizedSupportedSource(snap.source)
                return snapSource == normalized
                    && snap.cliPid == pid_t(ppid)
                    && snap.lastActivity >= cutoff
                    && sessionId != excludedSessionId
                    && (!requireActive || snap.status != .idle)
            }
            .sorted { lhs, rhs in
                let lhsActive = lhs.value.status != .idle
                let rhsActive = rhs.value.status != .idle
                if lhsActive != rhsActive { return lhsActive }
                return lhs.value.startTime < rhs.value.startTime
            }
            .first?.key
    }

    func findSessionId(providerSessionId: String) -> String? {
        if sessions[providerSessionId] != nil {
            return providerSessionId
        }
        let codexAppId = AppState.codexAppSessionPrefix + providerSessionId
        if sessions[codexAppId] != nil {
            return codexAppId
        }
        return sessions.first(where: { _, snap in
            snap.providerSessionId == providerSessionId
        })?.key
    }

    /// Resolve a Codex parent in the same Desktop/CLI namespace as its child.
    /// Raw and `codexapp:` cards may legitimately share a provider thread id
    /// when a user resumes the same thread in both surfaces.
    func findCodexParentSessionId(
        providerSessionId: String,
        childTermBundleId: String?
    ) -> String? {
        let childIsDesktop = childTermBundleId == Self.codexAppBundleId
        let canonicalId = childIsDesktop
            ? Self.codexAppSessionPrefix + providerSessionId
            : providerSessionId
        if let session = sessions[canonicalId],
           session.source == "codex",
           session.isNativeAppMode == childIsDesktop {
            return canonicalId
        }
        return sessions.first(where: { _, snapshot in
            snapshot.source == "codex"
                && snapshot.providerSessionId == providerSessionId
                && snapshot.isNativeAppMode == childIsDesktop
        })?.key
    }

    func denyPermission(expectedSessionId: String? = nil) {
        guard let index = permissionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "deny")
            }
            return
        }
        let pending = permissionQueue.remove(at: index)
        let sessionId = pending.event.sessionId ?? "default"
        PetReactionCenter.shared.permissionClosed(requestId: pending.id)
        dismissedPermissionSessionIds.remove(sessionId)
        let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#
        pending.continuation.resume(returning: Data(response.utf8))
        // Folded Task deny must not idle the whole parent chat card.
        resolveMergedSubagentAfterUI(
            sessionId: sessionId,
            agentId: pending.event.agentId,
            subagentStatus: .processing,
            keepSubagentTool: nil,
            idleParentWhenNoAgent: true
        )

        if activeSessionId == sessionId {
            activeSessionId = mostActiveSessionId()
        }

        showNextPending()
        refreshDerivedState()
    }

    func dismissPermissionPrompt(expectedSessionId: String? = nil) {
        guard let index = permissionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "dismiss")
            }
            return
        }
        let pending = permissionQueue[index]

        let sessionId = pending.event.sessionId ?? "default"
        dismissedPermissionSessionIds.insert(sessionId)

        if nextVisiblePermissionIndex() != nil {
            showNextPending()
        } else {
            if case .approvalCard = surface {
                withAnimation(NotchAnimation.close) {
                    surface = .collapsed
                }
            }
        }
        refreshDerivedState()
    }

    func handleQuestion(_ event: HookEvent, continuation: CheckedContinuation<Data, Never>) {
        let sessionId = event.sessionId ?? "default"
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }
        if event.agentId == nil {
            extractMetadata(into: &sessions, sessionId: sessionId, event: event)
        } else {
            fillMissingParentMetadataFromSubagentEvent(into: &sessions, sessionId: sessionId, event: event)
        }
        tryMonitorSession(sessionId)

        if shouldSuppressClosedSubagentUI(sessionId: sessionId, agentId: event.agentId) {
            continuation.resume(returning: Data("{}".utf8))
            return
        }

        guard let question = QuestionPayload.from(event: event) else {
            continuation.resume(returning: Data("{}".utf8))
            return
        }
        drainPermissions(forSession: sessionId, reason: "handleQuestion(Notification)", where: { $0.agentId == event.agentId })

        sessions[sessionId]?.status = .waitingQuestion
        sessions[sessionId]?.lastActivity = Date()
        markMergedSubagentWaiting(sessionId: sessionId, agentId: event.agentId, status: .waitingQuestion)

        let request = QuestionRequest(event: event, question: question, continuation: continuation)
        questionQueue.append(request)

        // First of a burst: nothing else visibly waiting. Not `count == 1` —
        // a closed question stays queued, and must not swallow every later
        // question's card and sound (the trap #309 fixed for approvals).
        if nextVisibleQuestion?.id == request.id {
            activeSessionId = sessionId
            if Self.autoExpandOnQuestion(), shouldAutoOpenPendingSurface(for: sessionId) {
                withAnimation(NotchAnimation.open) {
                    surface = .questionCard(sessionId: sessionId)
                }
            }
            SoundManager.shared.handleEvent("PermissionRequest", sessionId: sessionId, source: sessions[sessionId]?.mascotSource)
        }
        refreshDerivedState()
    }

    func handleAskUserQuestion(_ event: HookEvent, continuation: CheckedContinuation<Data, Never>) {
        let sessionId = event.sessionId ?? "default"
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }
        if event.agentId == nil {
            extractMetadata(into: &sessions, sessionId: sessionId, event: event)
        } else {
            fillMissingParentMetadataFromSubagentEvent(into: &sessions, sessionId: sessionId, event: event)
        }
        tryMonitorSession(sessionId)

        if shouldSuppressClosedSubagentUI(sessionId: sessionId, agentId: event.agentId) {
            let denyResponse = Data(
                #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8
            )
            continuation.resume(returning: denyResponse)
            return
        }

        let originalQuestions = event.toolInput?["questions"] as? [[String: Any]]
        var askItems: [AskUserQuestionItem] = []
        if let questions = originalQuestions {
            var usedAnswerKeys = Set<String>()
            askItems = questions.enumerated().compactMap { index, item in
                let questionText = item["question"] as? String ?? "Question"
                let header = item["header"] as? String
                let multiSelect = item["multiSelect"] as? Bool ?? false
                var optionLabels: [String]?
                var optionDescs: [String]?
                if let opts = item["options"] as? [[String: Any]] {
                    optionLabels = opts.compactMap { $0["label"] as? String }
                    optionDescs = opts.compactMap { $0["description"] as? String }
                }
                if optionLabels?.isEmpty == true { optionLabels = nil }
                if optionDescs?.isEmpty == true { optionDescs = nil }
                let payload = QuestionPayload(
                    question: questionText,
                    options: optionLabels,
                    descriptions: optionDescs,
                    header: header
                )
                // Claude Code's mapToolResultToToolResultBlockParam looks up answers by
                // question text: `answers[question.question]`. Using header as the key
                // causes a mismatch and all answers arrive as empty strings.
                let baseKey = questionText
                var answerKey = baseKey
                if usedAnswerKeys.contains(answerKey) {
                    var suffix = 2
                    while usedAnswerKeys.contains("\(baseKey)_\(suffix)") {
                        suffix += 1
                    }
                    answerKey = "\(baseKey)_\(suffix)"
                }
                usedAnswerKeys.insert(answerKey)
                return AskUserQuestionItem(payload: payload, answerKey: answerKey, multiSelect: multiSelect)
            }
        }

        if askItems.isEmpty {
            let questionText = event.toolInput?["question"] as? String ?? "Question"
            var options: [String]?
            if let stringOpts = event.toolInput?["options"] as? [String] {
                options = stringOpts
            } else if let dictOpts = event.toolInput?["options"] as? [[String: Any]] {
                options = dictOpts.compactMap { $0["label"] as? String }
            }
            if !questionText.isEmpty {
                let payload = QuestionPayload(question: questionText, options: options)
                askItems = [AskUserQuestionItem(payload: payload, answerKey: "answer", multiSelect: false)]
            }
        }

        guard !askItems.isEmpty else {
            let updatedInput = askUserQuestionUpdatedInput(
                event: event,
                answers: [:],
                answer: nil,
                originalQuestions: originalQuestions
            )
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedInput": updatedInput
                    ] as [String: Any]
                ] as [String: Any]
            ]
            let responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
            continuation.resume(returning: responseData)
            sessions[sessionId]?.status = .processing
            refreshDerivedState()
            return
        }

        drainPermissions(forSession: sessionId, reason: "handleAskUserQuestion", where: { $0.agentId == event.agentId })
        drainQuestions(forSession: sessionId, reason: "handleAskUserQuestion", where: { $0.agentId == event.agentId })

        sessions[sessionId]?.status = .waitingQuestion
        sessions[sessionId]?.lastActivity = Date()
        markMergedSubagentWaiting(sessionId: sessionId, agentId: event.agentId, status: .waitingQuestion)

        let askState = AskUserQuestionState(items: askItems, answers: [:])
        let request = QuestionRequest(
            event: event,
            question: askItems[0].payload,
            continuation: continuation,
            isFromPermission: true,
            askUserQuestionState: askState
        )
        questionQueue.append(request)

        // First of a burst, as in `handleQuestion`.
        if nextVisibleQuestion?.id == request.id {
            activeSessionId = sessionId
            if Self.autoExpandOnQuestion(), shouldAutoOpenQuestionSurface(for: event) {
                withAnimation(NotchAnimation.open) {
                    surface = .questionCard(sessionId: sessionId)
                }
            }
            SoundManager.shared.handleEvent("PermissionRequest", sessionId: sessionId, source: sessions[sessionId]?.mascotSource)
        }
        refreshDerivedState()
    }

    func answerQuestion(_ answer: String, expectedSessionId: String? = nil) {
        guard let index = questionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "answer")
            }
            return
        }
        // Multi-question wizards (AskUserQuestion, Codex app-server) use the batch
        // path — direct single answers are not processed.
        if questionQueue[index].askUserQuestionState != nil,
           (questionQueue[index].isFromPermission || questionQueue[index].isCodexAppServer) {
            return
        }
        // Codex app-server questions reply over the JSON-RPC client, not a hook.
        if questionQueue[index].isCodexAppServer {
            let pending = questionQueue.remove(at: index)
            let answerKey = pending.askUserQuestionState?.items.first?.answerKey
                ?? pending.question.header ?? "answer"
            pending.resolveCodexAppServer([answerKey: [answer]])
            let sessionId = pending.event.sessionId ?? "default"
            sessions[sessionId]?.status = .processing
            showNextPending()
            refreshDerivedState()
            return
        }
        let pending = questionQueue.remove(at: index)
        let responseData: Data
        if pending.isFromPermission {
            let answerKey = pending.question.header ?? "answer"
            let updatedInput = askUserQuestionUpdatedInput(
                event: pending.event,
                answers: [answerKey: answer],
                answer: answer,
                originalQuestions: pending.event.toolInput?["questions"] as? [[String: Any]]
            )
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedInput": updatedInput
                    ] as [String: Any]
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        } else {
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "Notification",
                    "answer": answer
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        }
        pending.resolution.resumeHook(returning: responseData)
        let sessionId = pending.event.sessionId ?? "default"
        resolveMergedSubagentAfterUI(
            sessionId: sessionId,
            agentId: pending.event.agentId,
            subagentStatus: .running,
            keepSubagentTool: nil,
            idleParentWhenNoAgent: false
        )

        showNextPending()
        refreshDerivedState()
    }

    func answerQuestionMulti(
        _ answers: [(question: String, answer: String)],
        expectedSessionId: String? = nil
    ) {
        answerQuestionMulti(
            answers.map {
                AskUserQuestionAnswer(
                    question: $0.question,
                    answer: $0.answer,
                    selectedOptions: [],
                    customInput: nil
                )
            },
            expectedSessionId: expectedSessionId
        )
    }

    func answerQuestionMulti(
        _ answers: [AskUserQuestionAnswer],
        expectedSessionId: String? = nil
    ) {
        guard let index = questionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "answer")
            }
            return
        }
        // Wizard answers are mapped onto items by position below. A set that
        // is not exactly one answer per this request's questions was collected
        // for some other request — delivering it would answer this CLI's
        // question with another session's answer — so it is refused and the
        // request stays waiting. (#333)
        if let askState = questionQueue[index].askUserQuestionState,
           !askState.accepts(answers) {
            let sessionId = questionQueue[index].event.sessionId ?? "default"
            log.notice("⚠️ refused answers for session=\(sessionId, privacy: .public) — \(answers.count, privacy: .public) answer(s) do not match its \(askState.items.count, privacy: .public) question(s)")
            refreshDerivedState()
            return
        }
        // Codex app-server questions reply over the JSON-RPC client, not a hook.
        if questionQueue[index].isCodexAppServer {
            let pending = questionQueue.remove(at: index)
            var answersByKey: [String: [String]] = [:]
            if let askState = pending.askUserQuestionState {
                // Match by position — the wizard collects answers in item order.
                for (index, item) in askState.items.enumerated() where index < answers.count {
                    answersByKey[item.answerKey] = [answers[index].answer]
                }
            } else {
                let answerKey = pending.question.header ?? "answer"
                answersByKey[answerKey] = [answers.first?.answer ?? ""]
            }
            pending.resolveCodexAppServer(answersByKey)
            let sessionId = pending.event.sessionId ?? "default"
            sessions[sessionId]?.status = .processing
            showNextPending()
            refreshDerivedState()
            return
        }
        let pending = questionQueue.remove(at: index)
        let responseData: Data
        if pending.isFromPermission {
            var answersDict: [String: String] = [:]
            var answerDetails: [String: [String: Any]] = [:]
            if let askState = pending.askUserQuestionState {
                // Match by position — wizard collects answers in the same order as items
                for (index, item) in askState.items.enumerated() {
                    if index < answers.count {
                        let submitted = answers[index]
                        answersDict[item.answerKey] = submitted.answer
                        var details: [String: Any] = [:]
                        if !submitted.selectedOptions.isEmpty {
                            details["selectedOptions"] = submitted.selectedOptions
                        }
                        if let customInput = submitted.customInput {
                            details["customInput"] = customInput
                        }
                        if !details.isEmpty {
                            answerDetails[item.answerKey] = details
                        }
                    }
                }
            } else {
                let answerKey = pending.question.header ?? "answer"
                answersDict[answerKey] = answers.first?.answer ?? ""
            }
            let updatedInput = askUserQuestionUpdatedInput(
                event: pending.event,
                answers: answersDict,
                answer: answers.first?.answer,
                originalQuestions: pending.event.toolInput?["questions"] as? [[String: Any]],
                answerDetails: answerDetails
            )
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedInput": updatedInput
                    ] as [String: Any]
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        } else {
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "Notification",
                    "answer": answers.first?.answer ?? ""
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        }
        pending.resolution.resumeHook(returning: responseData)
        let sessionId = pending.event.sessionId ?? "default"
        resolveMergedSubagentAfterUI(
            sessionId: sessionId,
            agentId: pending.event.agentId,
            subagentStatus: .running,
            keepSubagentTool: nil,
            idleParentWhenNoAgent: false
        )

        showNextPending()
        refreshDerivedState()
    }

    private func askUserQuestionUpdatedInput(
        event: HookEvent,
        answers: [String: String],
        answer: String?,
        originalQuestions: [[String: Any]]?,
        answerDetails: [String: [String: Any]] = [:]
    ) -> [String: Any] {
        var updatedInput = event.toolInput ?? [:]
        // `questions` must always be present in updatedInput. Claude Code's
        // mapToolResultToToolResultBlockParam calls H.map() on it directly;
        // if the key is absent H is undefined and the call crashes with
        // "undefined is not an object (evaluating 'H.map')".
        // Fall back to the raw toolInput value when the [[String:Any]] cast fails.
        updatedInput["questions"] = originalQuestions ?? (event.toolInput?["questions"] ?? [] as [[String: Any]])
        updatedInput["answers"] = answers
        if let answer {
            updatedInput["answer"] = answer
        }
        // Structured picks for OpenCode, whose multi-select answers are
        // `string[]` (v1) or a multiselect form field (v2) — a ", "-joined
        // display string can't be split back when a label itself contains
        // ", " (#332).
        let detailsSource = SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String)
        if !answerDetails.isEmpty, detailsSource == "opencode" {
            updatedInput["_codeislandAnswerDetails"] = answerDetails
        }
        return updatedInput
    }

    /// Close a question card without answering it. The request stays queued
    /// and the agent keeps waiting: answer it in the terminal, or reopen the
    /// card from the collapsed bar's question badge. Skip, by contrast,
    /// answers — for AskUserQuestion it denies the tool call.
    func dismissQuestion(expectedSessionId: String? = nil) {
        guard let index = questionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "dismiss")
            }
            return
        }
        dismissedQuestionIds.insert(questionQueue[index].id)

        if case .questionCard = surface {
            withAnimation(NotchAnimation.close) {
                surface = .collapsed
            }
        }
        // Hand the panel to whatever is still visibly waiting, if it may open.
        showNextPending()
        refreshDerivedState()
    }

    func skipQuestion(expectedSessionId: String? = nil) {
        guard let index = questionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "skip")
            }
            return
        }
        let pending = questionQueue.remove(at: index)
        if pending.isCodexAppServer {
            // No "skip" verb in the Codex protocol — abandon the request so the
            // server stops waiting (it will re-prompt or fall back to its TUI).
            pending.resolveCodexAppServer(nil)
        } else {
            let responseData: Data
            if pending.isFromPermission {
                responseData = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
            } else {
                responseData = Data(#"{"hookSpecificOutput":{"hookEventName":"Notification"}}"#.utf8)
            }
            pending.resolution.resumeHook(returning: responseData)
        }
        let sessionId = pending.event.sessionId ?? "default"
        resolveMergedSubagentAfterUI(
            sessionId: sessionId,
            agentId: pending.event.agentId,
            subagentStatus: .processing,
            keepSubagentTool: nil,
            idleParentWhenNoAgent: false
        )

        showNextPending()
        refreshDerivedState()
    }

    /// Drain queued permissions for a specific session, resuming their continuations with deny.
    /// `matches` narrows the drain by the request's event — background subagents share the
    /// parent's session_id, so callers reacting to one agent pass an agent_id filter.
    private func drainPermissions(
        forSession sessionId: String,
        reason: String = "unknown",
        where matches: (HookEvent) -> Bool = { _ in true }
    ) {
        dismissedPermissionSessionIds.remove(sessionId)
        let denyResponse = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
        permissionQueue.removeAll { item in
            guard item.event.sessionId == sessionId, matches(item.event) else { return false }
            log.notice("⚠️ permission deny reason=drainPermissions(\(reason, privacy: .public)) session=\(sessionId, privacy: .public) toolUseId=\(item.toolUseId ?? "nil", privacy: .public) tool=\(item.event.toolName ?? "nil", privacy: .public)")
            item.continuation.resume(returning: denyResponse)
            return true
        }
    }

    /// Called when the bridge socket disconnects — the question/permission was answered externally (e.g. user replied in terminal).
    /// Only the disconnecting agent's requests are drained: the socket belonged to one agent,
    /// and another agent's request in the same session is still waiting on the user.
    func handlePeerDisconnect(sessionId: String, agentId: String? = nil) {
        let sameAgent: (HookEvent) -> Bool = { $0.sessionId == sessionId && $0.agentId == agentId }
        let hadPending = questionQueue.contains(where: { sameAgent($0.event) })
            || permissionQueue.contains(where: { sameAgent($0.event) })
        guard hadPending else { return }

        drainQuestions(forSession: sessionId, reason: "peer-disconnect", where: sameAgent)
        drainPermissions(forSession: sessionId, reason: "peer-disconnect", where: sameAgent)
        let currentStatus = sessions[sessionId]?.status
        let wasWaiting = currentStatus == .waitingApproval || currentStatus == .waitingQuestion
        if wasWaiting, permissionQueue.contains(where: { $0.event.sessionId == sessionId }) {
            sessions[sessionId]?.status = .waitingApproval
        } else if wasWaiting, questionQueue.contains(where: { $0.event.sessionId == sessionId }) {
            sessions[sessionId]?.status = .waitingQuestion
        } else if wasWaiting {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
        showNextPending()
        refreshDerivedState()
    }

    /// Drain all queued questions for a specific session.
    /// AskUserQuestion-derived requests are denied; notification questions return empty.
    private func drainQuestions(
        forSession sessionId: String,
        reason: String = "unknown",
        where matches: (HookEvent) -> Bool = { _ in true }
    ) {
        questionQueue.removeAll { item in
            guard item.event.sessionId == sessionId, matches(item.event) else { return false }
            if item.isCodexAppServer {
                // Abandon the Codex app-server request so the server stops waiting.
                item.resolveCodexAppServer(nil)
            } else if item.isFromPermission {
                log.notice("⚠️ permission deny reason=drainQuestions(\(reason, privacy: .public)) session=\(sessionId, privacy: .public) tool=AskUserQuestion")
                let denyData = Data(
                    #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
                item.resolution.resumeHook(returning: denyData)
            } else {
                item.resolution.resumeHook(returning: Data("{}".utf8))
            }
            return true
        }
    }

    /// A card the user can no longer act on must never stay on screen: the panel
    /// would sit expanded showing a request that is gone or dismissed, and any
    /// click landing on it can only be discarded. Auto-open suppression decides
    /// whether to open a *new* card, not whether to keep a dead one, so this
    /// runs unconditionally. (#308)
    ///
    /// "Dead" is the same predicate `nextVisiblePermissionIndex()` applies:
    /// dismissed counts as not visible. Testing queue membership alone would
    /// keep a dismissed card up, because dismissing hides without dequeuing.
    private func collapseStaleCardSurface() {
        switch surface {
        case .approvalCard(let sid)
            where pendingPermission(forSession: sid) == nil
                || dismissedPermissionSessionIds.contains(sid):
            surface = .collapsed
        case .questionCard(let sid) where pendingQuestion(forSession: sid) == nil:
            surface = .collapsed
        default:
            break
        }
    }

    /// After dequeuing, show the next pending item, else the next finished
    /// turn, else collapse.
    ///
    /// Returns whether something the user can act on is on screen afterwards:
    /// an approval / question card, or the session list (which answers them
    /// inline), or the next completion card. A request that stays hidden —
    /// its auto-expand switch is off, Smart Suppress holds it back — is not
    /// on screen: a completion card whose time is up then moves on to the
    /// next finished turn or folds, instead of staying up for nobody.
    @discardableResult
    func showNextPending() -> Bool {
        collapseStaleCardSurface()
        let hasPending: Bool
        if let idx = nextVisiblePermissionIndex() {
            hasPending = true
            // An approval card still showing the request it was opened for
            // stays — the user may have picked it (session list, reminder)
            // over the head. It becomes the head, so whatever acts on the
            // head agrees with the screen.
            let shownIdx = shownApprovalIndex
            // One assignment: removing and re-inserting in place would show
            // the queue's observers a moment where this request is gone.
            var queue = permissionQueue
            let next = queue.remove(at: shownIdx ?? idx)
            queue.insert(next, at: 0)
            permissionQueue = queue
            let sid = next.event.sessionId ?? "default"
            activeSessionId = sid
            if shownIdx != nil { return true }
            // When the session list is open, keep it open; approvals can be handled inline.
            // Not behind the den's back: it has no rows, and it stays open.
            if surface == .sessionList, !denShowsSettings { return true }
            if Self.autoExpandOnPermission(), shouldAutoOpenPendingSurface(for: sid) {
                surface = .approvalCard(sessionId: sid)
                return true
            }
            // The approval stays hidden; a card already up stays with it.
            if surface.approvalSessionId != nil || surface.questionSessionId != nil { return true }
        } else if let next = nextVisibleQuestion {
            hasPending = true
            // A question card still showing the question it was opened for
            // stays, even when it is not the head (the user clicked "Answer"
            // on it, a reminder reopened it).
            if let shown = shownQuestionSessionId {
                activeSessionId = shown
                return true
            }
            let sid = next.event.sessionId ?? "default"
            activeSessionId = sid
            if !Self.autoExpandOnQuestion() {
                // Nothing opens by itself — and a card the user opened with a
                // click stays put. Stale cards were already folded above.
                if surface.questionSessionId != nil || surface == .sessionList { return true }
            } else if shouldAutoOpenQuestionSurface(for: next.event) {
                surface = .questionCard(sessionId: sid)
                return true
            } else if case .questionCard = surface {
                // Smart Suppress wants this card collapsed (e.g. an OMP ask
                // whose terminal dialog is racing). Fold an inherited
                // question-card surface so the promoted card does not render
                // expanded on top of the previous question's surface.
                surface = .collapsed
            } else if surface == .sessionList {
                return true
            }
        } else {
            hasPending = false
        }
        // Nothing interactive on screen. A completion card that is up keeps
        // its own time (`showNextCompletionOrCollapse` moves on when it is
        // over); a request arriving hidden must not cut it short.
        if !hasPending || !isShowingCompletion, showNextQueuedCompletion() {
            return true
        }
        if surface.approvalSessionId != nil || surface.questionSessionId != nil {
            surface = .collapsed
        }
        return false
    }

    /// Show the oldest queued completion whose session still exists.
    private func showNextQueuedCompletion() -> Bool {
        while let next = completionQueue.first {
            completionQueue.removeFirst()
            if let session = sessions[next] {
                // Smart Suppress, as `showCompletion` applies it. The tab
                // probe would block here, so only the cases the app alone
                // decides (Claude Desktop, native agent apps, IDEs) are dropped.
                if shouldSuppressAppLevel(for: next),
                   TerminalVisibilityDetector.visibilityWhenAppFrontmost(session) == true {
                    continue
                }
                withAnimation(NotchAnimation.pop) { doShowCompletion(next) }
                return true
            }
        }
        return false
    }

    /// Find the most recently active non-idle session
    private func mostActiveSessionId() -> String? {
        // Pick the most urgent session: highest status priority, then most recent activity
        sessions.max { a, b in
            let pa = statusPriority(a.value.status)
            let pb = statusPriority(b.value.status)
            if pa != pb { return pa < pb }
            return a.value.lastActivity < b.value.lastActivity
        }?.key
    }

    /// Read Claude model from a session transcript file.
    private nonisolated static func readModelFromTranscript(sessionId: String, cwd: String?) -> String? {
        guard let cwd = cwd else { return nil }
        let projectDir = cwd.claudeProjectDirEncoded()
        // The transcript sits under whichever config dir (account) ran it.
        guard let path = ClaudeConfigPaths.transcriptPath(projectDir: projectDir, sessionId: sessionId),
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }
        let chunk = handle.readData(ofLength: 32768)
        guard let text = String(data: chunk, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let model = message["model"] as? String, !model.isEmpty
            else { continue }
            return model
        }
        return nil
    }

    private nonisolated static func readModelForSession(sessionId: String, session: SessionSnapshot) -> String? {
        guard let source = SessionSnapshot.normalizedSupportedSource(session.source) else { return nil }
        let processStart = session.cliStartTime ?? session.cliPid.flatMap { liveProcessIdentity(for: $0)?.startTime }

        switch source {
        case "claude":
            return readModelFromTranscript(sessionId: sessionId, cwd: session.cwd)
        case "codex":
            return readModelFromCodexStore(cwd: session.cwd, processStart: processStart)
        case "opencode":
            return readModelFromOpenCodeStore(cwd: session.cwd, processStart: processStart)
        default:
            return nil
        }
    }

    private nonisolated static func readModelFromCodexStore(cwd: String?, processStart: Date?) -> String? {
        guard let cwd else { return nil }
        let fm = FileManager.default
        guard let path = codexStateRoots().lazy.compactMap({
            findRecentCodexSession(base: "\($0)/sessions", cwd: cwd, after: processStart, fm: fm)
        }).first else {
            return nil
        }
        return readRecentFromCodexTranscript(path: path).0
    }

    private nonisolated static func codexLatestFinishedTurnTimestamp(
        sessionId: String,
        session: SessionSnapshot
    ) -> Date? {
        let effectiveSessionId: String
        if let providerSessionId = session.providerSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !providerSessionId.isEmpty {
            effectiveSessionId = providerSessionId
        } else {
            effectiveSessionId = sessionId
        }
        let processStart = session.cliStartTime ?? session.cliPid.flatMap { liveProcessIdentity(for: $0)?.startTime }

        guard let transcriptPath = codexTranscriptPath(
            sessionId: effectiveSessionId,
            cwd: session.cwd,
            processStart: processStart
        ),
              let tail = readTranscriptTail(path: transcriptPath, maxBytes: 131072) else {
            return nil
        }

        return codexLatestTerminalTurnTimestamp(in: tail)
    }

    private nonisolated static func nativeAppFinishedTurnTimestamp(
        sessionId: String,
        session: SessionSnapshot
    ) -> Date? {
        switch session.source {
        case "codex":
            return codexLatestFinishedTurnTimestamp(sessionId: sessionId, session: session)
        default:
            return nil
        }
    }

    private nonisolated static func codexTranscriptPath(
        sessionId: String,
        cwd: String?,
        processStart: Date?
    ) -> String? {
        // The thread may belong to any Codex root (CODEX_HOME / account).
        let roots = codexStateRoots()
        for root in roots {
            let statePath = "\(root)/state_5.sqlite"

            if let path: String = withSQLiteDatabase(at: statePath, body: { db in
                guard let statement = prepareSQLiteStatement(
                    db: db,
                    sql: """
                        SELECT rollout_path
                        FROM threads
                        WHERE id = ?
                        LIMIT 1;
                        """
                ) else {
                    return nil
                }
                defer { sqlite3_finalize(statement) }

                bindSQLiteText(sessionId, to: statement, index: 1)
                guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                return sqliteColumnString(statement, index: 0)
            }),
               FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        guard let cwd else { return nil }
        return roots.lazy.compactMap {
            findRecentCodexSession(base: "\($0)/sessions", cwd: cwd, after: processStart, fm: .default)
        }.first
    }

    /// `storeSessionId`, when the card's key names the store row, is read
    /// first; the cwd match is the fallback.
    nonisolated static func readModelFromOpenCodeStore(
        cwd: String?,
        processStart: Date?,
        dbPath: String = openCodeDatabasePath(),
        rootSessionsOnly: Bool = false,
        storeSessionId: String? = nil
    ) -> String? {
        return withSQLiteDatabase(at: dbPath) { db in
            if let storeSessionId,
               let model = readRecentFromOpenCodeSession(db: db, sessionId: storeSessionId).0 {
                return model
            }
            guard let cwd, let session = findRecentOpenCodeSession(
                in: db, cwd: cwd, after: processStart, rootSessionsOnly: rootSessionsOnly
            ) else {
                return nil
            }
            return readRecentFromOpenCodeSession(db: db, sessionId: session.sessionId).0
        }
    }

    // MARK: - Session Discovery (FSEventStream + process scan)
    // MARK: - Session Persistence

    func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.saveSessions()
            }
        }
    }

    func saveSessions() {
        SessionPersistence.save(sessions)
    }

    func restoreSessions() {
        let persisted = SessionPersistence.load()
        let cutoff = Date().addingTimeInterval(-30 * 60) // 30 minutes
        for p in persisted {
            // Restore persisted cliPid only if the process is still alive — avoids
            // stale sessions reappearing briefly after the app or IDE restarts (#46).
            let liveProcess = p.cliPid
                .flatMap { $0 > 0 ? ProcessIdentity(pid: $0, startTime: p.cliStartTime) : nil }
                .flatMap { Self.isLiveProcess($0) ? $0 : nil }
            // A conversation that is still open comes back however long ago it
            // finished: it stays until the den has shown it.
            guard p.lastActivity > cutoff || liveProcess != nil else { continue }
            guard let source = SessionSnapshot.normalizedSupportedSource(p.source) else { continue }
            let restoredSessionId = Self.canonicalRestoredCodexSessionId(
                sessionId: p.sessionId,
                source: source,
                providerSessionId: p.providerSessionId,
                termBundleId: p.termBundleId
            )
            guard sessions[restoredSessionId] == nil else { continue }
            var snapshot = SessionSnapshot(startTime: p.startTime)
            snapshot.cwd = p.cwd
            snapshot.source = source
            snapshot.model = p.model
            snapshot.sessionTitle = p.sessionTitle
            snapshot.sessionTitleSource = p.sessionTitleSource
            snapshot.providerSessionId = p.providerSessionId
            // Saved by an older build, a prompt may still open with the host's
            // injected `<system-reminder>`.
            snapshot.lastUserPrompt = p.lastUserPrompt
                .map { JSONLTailer.stripDisplayWrappers($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            snapshot.lastAssistantMessage = p.lastAssistantMessage
            if let prompt = p.lastUserPrompt {
                snapshot.addRecentMessage(ChatMessage(isUser: true, text: prompt))
            }
            if let reply = p.lastAssistantMessage {
                snapshot.addRecentMessage(ChatMessage(isUser: false, text: reply))
            }
            snapshot.termApp = p.termApp
            snapshot.ttyPath = p.ttyPath
            snapshot.termBundleId = p.termBundleId
            snapshot.claudeDesktopSessionId = p.claudeDesktopSessionId
            snapshot.lastActivity = p.lastActivity
            snapshot.transcriptPath = p.transcriptPath
            snapshot.recap = p.recap
            snapshot.reasoningEffort = p.reasoningEffort
            // A prompt typed while CodeIsland wasn't running supersedes the
            // saved recap; the transcript tail is the judge. Restored cards
            // don't always get a tailer, so check now rather than on attach.
            if snapshot.recap != nil, let path = snapshot.transcriptPath,
               let scan = JSONLTailer.scanFileTail(path: path) {
                _ = snapshot.applyTranscriptBackfill(scan)
            }
            if let closed = p.closedSubagentIds, !closed.isEmpty {
                snapshot.restoreClosedSubagentIds(closed)
            }
            if let agentTasks = p.agentTasks {
                snapshot.agentTasks = agentTasks
            }
            if let liveProcess {
                snapshot.cliPid = liveProcess.pid
                snapshot.cliStartTime = p.cliStartTime
            }
            // Status is not persisted, so a Claude turn that was mid-stream when
            // Burrow restarted came back idle and stayed asleep until its next
            // hook — minutes, for a big Write. Its live process and an open
            // transcript say it is still working.
            if snapshot.isClaude, snapshot.cliPid != nil,
               Self.claudeTranscriptTurn(atPath: snapshot.transcriptPath) == .open {
                snapshot.status = .processing
            }
            // Skip sessions whose process is dead and status was idle — nothing to show.
            if snapshot.cliPid == nil && snapshot.status == .idle && snapshot.lastUserPrompt == nil {
                continue
            }
            sessions[restoredSessionId] = snapshot
            refreshProviderTitle(for: restoredSessionId)
            // Branch is re-read, not persisted — it may have changed between runs.
            maybeRefreshGitBranch(
                for: restoredSessionId,
                cwdBefore: nil,
                normalizedEventName: "SessionStart"
            )
            // Reattach exit monitoring without changing the restored idle/running snapshot.
            tryMonitorSession(restoredSessionId)
        }
        SessionPersistence.clear()
        _ = applyCodexSubsessionModeToKnownSessions()
        if activeSessionId == nil {
            activeSessionId = sessions.first(where: { $0.value.status != .idle })?.key
                ?? sessions.keys.sorted().first
        }
        refreshDerivedState()
    }

    private nonisolated static func findDiscoveredSessions() -> [DiscoveredSession] {
        let candidatePids = allProcessIds()
        var discovered: [DiscoveredSession] = []
        if ConfigInstaller.isEnabled(source: "claude") {
            discovered.append(contentsOf: findActiveClaudeSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "codex") {
            discovered.append(contentsOf: findActiveCodexSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "opencode") {
            discovered.append(contentsOf: findActiveOpenCodeSessions(candidatePids: candidatePids))
        }
        return discovered
    }

    private nonisolated static func discoveryWatchRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates: [(String, String)] = [
            ("claude", ClaudeConfigPaths.projectsDir()),
            ("codex", "\(home)/.codex/sessions"),
            // $CODEX_HOME when CodeIsland itself was launched with one; the
            // same path as above otherwise (duplicates are dropped below).
            ("codex", "\(ConfigInstaller.codexHome())/sessions"),
            ("opencode", "\(home)/.local/share/opencode"),
        ]
        let fm = FileManager.default
        // By identity: `$CODEX_HOME` may be ~/.codex under another spelling
        // (symlink, case) and must not be watched twice.
        var seenRoots = Set<String>()
        return candidates.compactMap { source, path -> String? in
            guard ConfigInstaller.isEnabled(source: source), fm.fileExists(atPath: path),
                  seenRoots.insert(ConfigPathIdentity.identity(of: path)).inserted else { return nil }
            return path
        }
    }

    /// Root a Codex process without `$CODEX_HOME` uses.
    nonisolated static var defaultCodexRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.codex"
    }

    /// Codex roots whose state DB, rollouts and thread index may hold a given
    /// thread: `~/.codex`, where Codex Desktop keeps its state, then
    /// CodeIsland's own `$CODEX_HOME` when it was launched with another one.
    nonisolated static func codexStateRoots() -> [String] {
        let primary = ConfigInstaller.codexHome()
        guard ConfigPathIdentity.identity(of: primary) != ConfigPathIdentity.identity(of: defaultCodexRoot) else {
            return [defaultCodexRoot]
        }
        return [defaultCodexRoot, primary]
    }

    /// What a discovery scan runs. The real scan reads every process and the
    /// agents' session stores under ~, and each session it returns gets a
    /// process monitor — and the orphan reaper — on one of the user's real
    /// CLIs. A test process scans nothing unless a test installs a scanner.
    nonisolated(unsafe) static var discoveryScanner: @Sendable () -> [DiscoveredSession] = {
        RuntimeEnvironment.isRunningTests ? [] : findDiscoveredSessions()
    }

    private func requestDiscoveryScan() {
        if discoveryScanTask != nil {
            pendingDiscoveryRescan = true
            return
        }

        pendingDiscoveryRescan = false
        discoveryScanTask = Task.detached { [weak self] in
            let discovered = Self.discoveryScanner()
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else {
                    self.discoveryScanTask = nil
                    return
                }
                self.integrateDiscovered(discovered)
                self.discoveryScanTask = nil
                if self.pendingDiscoveryRescan {
                    self.pendingDiscoveryRescan = false
                    self.requestDiscoveryScan()
                }
            }
        }
    }

    /// FSEvents is not guaranteed to report every append below
    /// `~/.codex/sessions` on all macOS/filesystem combinations. Reuse the
    /// cleanup tick as a low-frequency fallback, but only while Codex Desktop
    /// is running and only after the polling interval has elapsed.
    nonisolated static func shouldPollCodexDesktopDiscovery(
        runningBundleIdentifiers: Set<String>,
        lastPollAt: Date?,
        now: Date,
        interval: TimeInterval = 6
    ) -> Bool {
        guard runningBundleIdentifiers.contains(codexAppBundleId) else { return false }
        guard let lastPollAt else { return true }
        return now.timeIntervalSince(lastPollAt) >= interval
    }

    func requestCodexDesktopDiscoveryScan() {
        guard codexDesktopDiscoveryScanTask == nil else { return }
        codexDesktopDiscoveryScanTask = Task.detached { [weak self] in
            let discovered = ConfigInstaller.isEnabled(source: "codex")
                ? Self.findRecentCodexDesktopSessions()
                : []
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else {
                    self.codexDesktopDiscoveryScanTask = nil
                    return
                }
                self.integrateDiscovered(discovered)
                self.codexDesktopDiscoveryScanTask = nil
            }
        }
    }

    func startSessionDiscovery() {
        startCleanupTimer()
        // Restore persisted sessions before process scan (deduped by scan)
        restoreSessions()

        // Initial scan for already-running sessions, respecting per-source toggles.
        requestDiscoveryScan()
        // Watch all known session-store roots so discovery keeps working when hooks are missed.
        startProjectsWatcher()
    }

    /// FSEventStream on known session-store roots — fires when transcript/event files change.
    private func startProjectsWatcher() {
        guard fsEventStream == nil else { return }
        let watchRoots = Self.discoveryWatchRoots()
        guard !watchRoots.isEmpty else { return }

        let box = ProjectsWatcherBox()
        box.appState = self

        var context = FSEventStreamContext()
        // Unretained box is owned by `projectsWatcherBox` until
        // `tearDownProjectsWatcher()`; the weak back-pointer keeps callbacks
        // safe across off-main `AppState` deinit.
        context.info = Unmanaged.passUnretained(box).toOpaque()

        let stream = FSEventStreamCreate(
            nil,
            { (_, info, _, _, _, _) in
                guard let info = info else { return }
                let box = Unmanaged<ProjectsWatcherBox>.fromOpaque(info).takeUnretainedValue()
                box.handleChange()
            },
            &context,
            watchRoots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,  // 2-second latency (coalesces rapid writes)
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagFileEvents
            )
        )

        guard let stream = stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.projectsWatcherBox = box
        self.fsEventStream = stream
        log.info("Discovery watcher started on \(watchRoots.joined(separator: ", "))")
    }

    /// Called by FSEventStream when a known session-store directory changes.
    nonisolated fileprivate func handleProjectsDirChange() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // FSEvents already coalesces writes with a two-second latency, and
            // requestDiscoveryScan() coalesces events that arrive during a scan.
            // Dropping events in an additional time window can miss the final
            // lifecycle write and leave the island showing stale state.
            self.requestDiscoveryScan()
        }
    }

    /// Provider thread IDs are authoritative when both sides have one. Two
    /// native Codex Desktop threads can legitimately share a source and CWD
    /// while having no PID, so they must not be collapsed into one card merely
    /// because the generic discovery heuristic sees the same project path.
    nonisolated static func providerSessionIdentifiersMayRepresentSameSession(
        existing: String?,
        discovered: String?
    ) -> Bool {
        guard let discovered, !discovered.isEmpty else { return true }
        guard let existing, !existing.isEmpty else { return false }
        return existing == discovered
    }

    /// Native-app and CLI discoveries are separate namespaces even when they
    /// share the same provider and working directory. In particular, a Codex
    /// CLI rollout has no native host bundle and must not be folded into a
    /// Codex Desktop card left by state-database discovery.
    nonisolated static func discoveryAppModesMayRepresentSameSession(
        existingIsNativeAppMode: Bool,
        discoveredTermBundleId: String?
    ) -> Bool {
        existingIsNativeAppMode == (discoveredTermBundleId != nil)
    }

    /// Completed Codex subagents are transient workers, not idle top-level
    /// sessions. Their spawn-edge row may remain `open`, so transcript lifecycle
    /// is the reliable signal for removing them from the island.
    nonisolated static func isCompletedCodexSubagentDiscovery(
        source: String,
        parentSessionId: String?,
        status: AgentStatus?
    ) -> Bool {
        source == "codex"
            && parentSessionId?.isEmpty == false
            && status == .idle
    }

    /// Update existing session's messages from discovered transcript data.
    private func backfillSessionMessages(sessionId: String, from info: DiscoveredSession) -> Bool {
        guard var session = sessions[sessionId], !info.recentMessages.isEmpty else { return false }
        guard info.modifiedAt >= session.lastActivity || session.recentMessages.isEmpty else {
            return false
        }
        var mutated = false
        let messagesChanged = session.recentMessages.count != info.recentMessages.count ||
            zip(session.recentMessages, info.recentMessages).contains { $0.isUser != $1.isUser || $0.text != $1.text }
        if messagesChanged {
            session.recentMessages = info.recentMessages
            mutated = true
        }
        if let lastUser = info.recentMessages.last(where: { $0.isUser }),
           session.lastUserPrompt != lastUser.text {
            session.lastUserPrompt = lastUser.text
            mutated = true
        }
        if let lastAssistant = info.recentMessages.last(where: { !$0.isUser }),
           session.lastAssistantMessage != lastAssistant.text {
            session.lastAssistantMessage = lastAssistant.text
            mutated = true
        }
        if mutated {
            sessions[sessionId] = session
        }
        return mutated
    }

    /// Merge discovered sessions into current state (skip already-known ones)
    func integrateDiscovered(_ discovered: [DiscoveredSession]) {
        var didMutate = false
        for info in discovered {
            if shouldSuppressClosedCodexDesktopDiscovery(info) {
                continue
            }
            if routeDiscoveredSubsessionIfNeeded(info) {
                didMutate = true
                continue
            }

            if Self.isCompletedCodexSubagentDiscovery(
                source: info.source,
                parentSessionId: info.parentSessionId,
                status: info.status
            ) {
                if sessions[info.sessionId] != nil {
                    removeSession(info.sessionId)
                    didMutate = true
                }
                continue
            }

            // Session already known — try to update PID and attach monitor.
            // Discovery PIDs are heuristic (matched by CWD), so when the session already
            // has a known-good alive PID that differs from discovery, we trust the existing
            // one for both cliPid and monitor to avoid cross-session contamination.
            if sessions[info.sessionId] != nil {
                if applyDiscoveredRuntimeState(info, to: info.sessionId) {
                    didMutate = true
                }
                if let pid = info.pid, pid > 0 {
                    let existingPid = sessions[info.sessionId]?.cliPid ?? 0
                    let existingProcess = resolvedSessionProcessIdentity(for: info.sessionId)
                    let existingAlive = existingProcess.map(Self.isLiveProcess) ?? false
                    if existingAlive && existingPid != pid {
                        // Existing PID is alive and different — discovery PID is unreliable.
                    } else {
                        // No existing PID, or it's dead, or it matches — safe to use discovery PID.
                        if !existingAlive, let process = Self.liveProcessIdentity(for: pid) {
                            setSessionProcessIdentity(process, for: info.sessionId)
                            didMutate = true
                        }
                    }
                }
                if backfillSessionMessages(sessionId: info.sessionId, from: info) {
                    didMutate = true
                }
                if applyDiscoveredMetadata(info, to: info.sessionId) {
                    didMutate = true
                }
                attachTranscriptTailerIfNeeded(sessionId: info.sessionId)
                tryMonitorSession(info.sessionId)
                refreshProviderTitle(
                    for: info.sessionId,
                    providerSessionId: info.providerSessionId ?? info.sessionId
                )
                continue
            }

            // Dedup: if a hook-created session already exists with same source + cwd + pid,
            // skip the discovered one to avoid duplicate entries (e.g. Codex hooks vs
            // file-based discovery produce different session IDs for the same process).
            // Only dedup when PID matches (or discovered has no PID), so concurrent
            // sessions in the same repo aren't incorrectly merged.
            // Never merge a discovery (CLI) session with an existing native app session —
            // they're fundamentally different even if they share source + cwd.
            let duplicateKey = sessions.first(where: { (_, existing) in
                guard existing.source == info.source,
                      existing.cwd != nil, existing.cwd == info.cwd else { return false }
                guard Self.discoveryAppModesMayRepresentSameSession(
                    existingIsNativeAppMode: existing.isNativeAppMode,
                    discoveredTermBundleId: info.termBundleId
                ) else { return false }
                guard Self.providerSessionIdentifiersMayRepresentSameSession(
                    existing: existing.providerSessionId,
                    discovered: info.providerSessionId
                ) else { return false }
                // Don't merge CLI discovery into a stale native app session whose app has quit —
                // the PID was likely reattached incorrectly. If the native app IS running, allow merge.
                if existing.isNativeAppMode,
                   let bid = existing.termBundleId,
                   !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bid }) {
                    return false
                }
                // If we have PIDs for both and the existing one is still alive, they must match.
                // Dead persisted PIDs should not block dedup / reattachment.
                if let discoveredPid = info.pid, let existingPid = existing.cliPid,
                   discoveredPid != existingPid,
                   Self.isLiveProcess(ProcessIdentity(pid: existingPid, startTime: existing.cliStartTime)) { return false }
                return true
            })?.key

            if let existingKey = duplicateKey {
                if applyDiscoveredRuntimeState(info, to: existingKey) {
                    didMutate = true
                }
                // Same guard as above: don't let unreliable discovery PID contaminate
                // an existing session that has a known-good alive PID.
                if let pid = info.pid, pid > 0 {
                    let existingPid = sessions[existingKey]?.cliPid ?? 0
                    let existingProcess = resolvedSessionProcessIdentity(for: existingKey)
                    let existingAlive = existingProcess.map(Self.isLiveProcess) ?? false
                    if existingAlive && existingPid != pid {
                    } else {
                        if !existingAlive, let process = Self.liveProcessIdentity(for: pid) {
                            setSessionProcessIdentity(process, for: existingKey)
                            didMutate = true
                        }
                    }
                }
                if backfillSessionMessages(sessionId: existingKey, from: info) {
                    didMutate = true
                }
                if applyDiscoveredMetadata(info, to: existingKey) {
                    didMutate = true
                }
                attachTranscriptTailerIfNeeded(sessionId: existingKey)
                tryMonitorSession(existingKey)
                refreshProviderTitle(
                    for: existingKey,
                    providerSessionId: info.providerSessionId ?? info.sessionId
                )
                continue
            }

            var session = SessionSnapshot(startTime: info.modifiedAt)
            session.cwd = info.cwd
            session.model = info.model
            session.ttyPath = info.tty
            session.recentMessages = info.recentMessages
            session.source = info.source
            session.status = info.status ?? .idle
            session.lastActivity = info.modifiedAt
            session.termBundleId = info.termBundleId
            if let pid = info.pid, let process = Self.liveProcessIdentity(for: pid) {
                session.cliPid = process.pid
                session.cliStartTime = process.startTime
            } else {
                session.cliPid = info.pid
            }
            session.providerSessionId = SessionTitleStore.supports(provider: info.source)
                ? (info.providerSessionId ?? info.sessionId)
                : nil
            if let last = info.recentMessages.last(where: { $0.isUser }) {
                session.lastUserPrompt = last.text
            }
            if let last = info.recentMessages.last(where: { !$0.isUser }) {
                session.lastAssistantMessage = last.text
            }
            session.transcriptPath = info.transcriptPath
            sessions[info.sessionId] = session
            refreshProviderTitle(
                for: info.sessionId,
                providerSessionId: info.providerSessionId ?? info.sessionId
            )
            tryMonitorSession(info.sessionId)
            attachTranscriptTailerIfNeeded(sessionId: info.sessionId)
            didMutate = true
        }
        if applyCodexSubsessionModeToKnownSessions() {
            didMutate = true
        }
        if didMutate && activeSessionId == nil {
            activeSessionId = sessions.keys.sorted().first
        }
        if didMutate {
            scheduleSave()
        }
        refreshDerivedState()
    }

    private func shouldSuppressClosedCodexDesktopDiscovery(_ info: DiscoveredSession) -> Bool {
        guard info.source == "codex",
              info.termBundleId == Self.codexAppBundleId,
              let providerSessionId = info.providerSessionId,
              let closedAt = closedCodexAppThreads[providerSessionId] else {
            return false
        }
        if info.modifiedAt <= closedAt {
            return true
        }
        // A terminal flush may land just after `thread/closed`; only a newer
        // processing lifecycle is evidence that the thread genuinely resumed.
        guard info.status == .processing else { return true }
        closedCodexAppThreads.removeValue(forKey: providerSessionId)
        return false
    }

    /// Apply runtime fields that filesystem/state-DB discovery can know more
    /// accurately than a stale restored snapshot. Interactive approval/question
    /// states remain authoritative until their owning channel resolves them.
    @discardableResult
    private func applyDiscoveredRuntimeState(_ info: DiscoveredSession, to sessionId: String) -> Bool {
        guard var session = sessions[sessionId] else { return false }
        var mutated = false
        let canApplyStatus = info.modifiedAt >= session.lastActivity

        if info.modifiedAt > session.lastActivity {
            session.lastActivity = info.modifiedAt
            mutated = true
        }
        if let bundleId = info.termBundleId,
           (canApplyStatus || session.termBundleId == nil),
           session.termBundleId != bundleId {
            session.termBundleId = bundleId
            mutated = true
        }
        if let discoveredStatus = info.status,
           canApplyStatus,
           session.status != .waitingApproval,
           session.status != .waitingQuestion,
           session.status != discoveredStatus {
            session.status = discoveredStatus
            if discoveredStatus == .idle {
                session.currentTool = nil
                session.toolDescription = nil
            }
            mutated = true
        }

        if mutated {
            sessions[sessionId] = session
        }
        return mutated
    }

    /// CWD and transcript path participate in tailer/process routing, so an old
    /// asynchronous scan must not rewind them after a newer DB result. Missing
    /// restored fields may still be filled regardless of timestamp.
    @discardableResult
    private func applyDiscoveredMetadata(_ info: DiscoveredSession, to sessionId: String) -> Bool {
        guard var session = sessions[sessionId] else { return false }
        let canReplace = info.modifiedAt >= session.lastActivity
        var mutated = false

        if (canReplace || session.cwd?.isEmpty != false), session.cwd != info.cwd {
            session.cwd = info.cwd
            mutated = true
        }
        if let path = info.transcriptPath,
           (canReplace || session.transcriptPath == nil),
           session.transcriptPath != path {
            session.transcriptPath = path
            mutated = true
        }
        if mutated {
            sessions[sessionId] = session
        }
        return mutated
    }

    @discardableResult
    func applyCodexSubsessionModeToKnownSessions(statePath: String? = nil) -> Bool {
        let mode = Self.currentPluginSessionMode()
        guard mode == "hide" || mode == "merge" else {
            return false
        }

        let candidates = sessions.map { (sessionId: $0.key, session: $0.value) }
        var transcriptMetadata: [String: CodexSubagentMetadata] = [:]
        var databaseLookupIds: Set<String> = []

        for candidate in candidates where candidate.session.source == "codex" {
            let providerSessionId = candidate.session.providerSessionId ?? candidate.sessionId
            if let transcriptPath = candidate.session.transcriptPath {
                switch Self.inspectCodexSubagentMetadata(inTranscriptPath: transcriptPath) {
                case .subagent(let metadata):
                    transcriptMetadata[candidate.sessionId] = metadata
                    databaseLookupIds.insert(providerSessionId)
                case .root:
                    // A readable root session_meta is definitive. Falling back
                    // to SQLite here turns every root card into a separate DB
                    // open and can also resurrect stale spawn-edge relations.
                    continue
                case .unavailable:
                    databaseLookupIds.insert(providerSessionId)
                }
            } else {
                databaseLookupIds.insert(providerSessionId)
            }
        }
        // One read-only DB connection for all candidates that genuinely need
        // relation/status fallback. Root transcripts never enter this query.
        let databaseRecords = Self.codexSpawnEdgeRecords(
            threadIds: databaseLookupIds,
            statePath: statePath
        )
        var didMutate = false

        for candidate in candidates where candidate.session.source == "codex" {
            let providerSessionId = candidate.session.providerSessionId ?? candidate.sessionId
            guard let metadata = transcriptMetadata[candidate.sessionId]
                    ?? databaseRecords[providerSessionId]?.metadata,
                  metadata.parentThreadId != providerSessionId else {
                continue
            }

            if mode == "hide" {
                if sessions[candidate.sessionId] != nil {
                    removeSession(candidate.sessionId)
                    didMutate = true
                }
                continue
            }

            guard let parentKey = findCodexParentSessionId(
                providerSessionId: metadata.parentThreadId,
                childTermBundleId: candidate.session.termBundleId
            ),
                  parentKey != candidate.sessionId else {
                continue
            }

            // Preserve the terminal snapshot before removeSession tears down the
            // child card. Transcript lifecycle is authoritative even when the
            // spawn edge is missing or remains "open".
            let completedByTranscript = candidate.session.status == .idle
            if sessions[candidate.sessionId] != nil {
                removeSession(candidate.sessionId)
                didMutate = true
            }

            if completedByTranscript
                || databaseRecords[providerSessionId]?.status?.lowercased() == "closed" {
                if sessions[parentKey]?.subagents.removeValue(forKey: providerSessionId) != nil {
                    if sessions[parentKey]?.subagents.isEmpty == true {
                        clearSubagentProjection(fromParentSession: parentKey)
                    }
                    didMutate = true
                }
                continue
            }

            let agentType = metadata.agentType ?? metadata.agentNickname ?? "Agent"
            var subagent = sessions[parentKey]?.subagents[providerSessionId]
                ?? SubagentState(agentId: providerSessionId, agentType: agentType)
            subagent.status = candidate.session.status
            subagent.currentTool = candidate.session.currentTool
            subagent.toolDescription = candidate.session.toolDescription ?? metadata.agentNickname
            if candidate.session.lastActivity > subagent.lastActivity {
                subagent.lastActivity = candidate.session.lastActivity
            }
            sessions[parentKey]?.subagents[providerSessionId] = subagent

            if sessions[parentKey]?.status != .waitingApproval && sessions[parentKey]?.status != .waitingQuestion {
                sessions[parentKey]?.status = .running
                sessions[parentKey]?.currentTool = "Agent"
                sessions[parentKey]?.toolDescription = metadata.agentNickname ?? agentType
            }
            if candidate.session.lastActivity > (sessions[parentKey]?.lastActivity ?? .distantPast) {
                sessions[parentKey]?.lastActivity = candidate.session.lastActivity
            }
            activeSessionId = parentKey
            didMutate = true
        }

        return didMutate
    }

    private func markMergedSubagentWaiting(
        sessionId: String,
        agentId: String?,
        status: AgentStatus
    ) {
        guard let agentId else { return }
        guard var session = sessions[sessionId] else { return }
        var subagent = session.subagents[agentId]
            ?? SubagentState(agentId: agentId, agentType: "cursor-subagent")
        subagent.status = status
        subagent.lastActivity = Date()
        session.subagents[agentId] = subagent
        sessions[sessionId] = session
    }

    /// After Permission/Question UI resolves for a possibly folded Task.
    /// With `agent_id`, never idle the parent — even if the subagent slot was
    /// already removed (Stop race). Uses local copies to avoid exclusivity traps
    /// when mutating nested `sessions[id].subagents[id]` fields.
    private func resolveMergedSubagentAfterUI(
        sessionId: String,
        agentId: String?,
        subagentStatus: AgentStatus,
        keepSubagentTool: String?,
        idleParentWhenNoAgent: Bool
    ) {
        if let agentId {
            guard var session = sessions[sessionId] else { return }
            if var subagent = session.subagents[agentId] {
                subagent.status = subagentStatus
                if subagentStatus == .processing {
                    subagent.currentTool = nil
                    subagent.toolDescription = nil
                } else if let keepSubagentTool {
                    subagent.currentTool = keepSubagentTool
                }
                session.subagents[agentId] = subagent
            }
            // One of Claude Code's own background agents: once its request is
            // answered, the conversation is back where its turn left it, not
            // working on the agent's behalf (Burrow design/v20 review).
            let background = session.subagents[agentId]?.outsideParentTurn == true
            let hasNonIdleSubagents = session.subagents.values.contains { $0.status != .idle && !$0.outsideParentTurn }
            if hasNonIdleSubagents {
                let agentType = session.subagents[agentId]?.agentType ?? "cursor-subagent"
                session.status = .running
                session.currentTool = "Agent"
                if session.toolDescription == nil {
                    session.toolDescription = agentType
                }
            } else {
                session.status = background ? .idle : .processing
                session.currentTool = nil
                session.toolDescription = nil
            }
            sessions[sessionId] = session
            return
        }

        if idleParentWhenNoAgent {
            sessions[sessionId]?.status = .idle
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        } else {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
    }

    /// Suppress Permission/Question UI for Stop'd Tasks: merged `agent_id` tombstones
    /// or separate-mode self-tombstones (card id recorded in ``closedSubagentIds``).
    private func shouldSuppressClosedSubagentUI(sessionId: String, agentId: String?) -> Bool {
        if let agentId, sessions[sessionId]?.hasClosedSubagentId(agentId) == true { return true }
        if agentId == nil, sessions[sessionId]?.hasClosedSubagentId(sessionId) == true { return true }
        return false
    }

    private nonisolated static func firstSubagentTranscript(
        in transcriptBase: String,
        sessionId: String,
        fm: FileManager
    ) -> String? {
        let suffix = "/subagents/\(sessionId).jsonl"
        guard let enumerator = fm.enumerator(atPath: transcriptBase) else { return nil }
        while let rel = enumerator.nextObject() as? String {
            if rel.hasSuffix(suffix) || rel == String(suffix.dropFirst()) {
                return "\(transcriptBase)/\(rel)"
            }
        }
        return nil
    }

    func applyCurrentPluginSessionMode(persist: Bool = true) {
        let mode = Self.currentPluginSessionMode()
        var didMutate = false

        switch mode {
        case "separate":
            didMutate = separateMergedCodexSubagents()
        case "merge":
            didMutate = applyCodexSubsessionModeToKnownSessions()
        case "hide":
            didMutate = applyCodexSubsessionModeToKnownSessions()
            didMutate = hideMergedCodexSubagents() || didMutate
        default:
            return
        }

        if didMutate {
            if persist {
                scheduleSave()
                startRotationIfNeeded()
            }
            refreshDerivedState()
        }
    }

    @discardableResult
    private func separateMergedCodexSubagents() -> Bool {
        let parentCandidates = sessions.map { (sessionId: $0.key, session: $0.value) }
        let childIds = Set(parentCandidates.flatMap { $0.session.subagents.keys })
        // One DB connection for the whole mode transition; never open SQLite
        // once per child (each open carries a busy timeout).
        let databaseRecords = Self.codexSpawnEdgeRecords(threadIds: childIds)
        var didMutate = false

        for parent in parentCandidates where parent.session.source == "codex" && !parent.session.subagents.isEmpty {
            for (agentId, subagent) in parent.session.subagents {
                let childIsDesktop = parent.session.termBundleId == Self.codexAppBundleId
                let childKey = findCodexParentSessionId(
                    providerSessionId: agentId,
                    childTermBundleId: parent.session.termBundleId
                ) ?? Self.codexDiscoveryIdentity(
                    rawSessionId: agentId,
                    isDesktop: childIsDesktop
                ).sessionId
                guard childKey != parent.sessionId else { continue }

                var child = sessions[childKey] ?? SessionSnapshot(startTime: subagent.startTime)
                child.source = "codex"
                child.providerSessionId = agentId
                child.cwd = child.cwd ?? parent.session.cwd
                // The child's own model (its hooks, then its rollout below) —
                // never the parent's: children routinely run on another model.
                child.model = child.model ?? subagent.model
                child.reasoningEffort = child.reasoningEffort ?? subagent.reasoningEffort
                child.permissionMode = child.permissionMode ?? parent.session.permissionMode
                child.termApp = child.termApp ?? parent.session.termApp
                child.ttyPath = child.ttyPath ?? parent.session.ttyPath
                child.termBundleId = child.termBundleId ?? parent.session.termBundleId
                child.cliPid = child.cliPid ?? parent.session.cliPid
                child.cliStartTime = child.cliStartTime ?? parent.session.cliStartTime
                child.status = subagent.status
                child.currentTool = subagent.currentTool
                child.toolDescription = subagent.toolDescription ?? subagent.agentType
                child.lastActivity = subagent.lastActivity

                let transcriptMetadata = child.transcriptPath.flatMap {
                    Self.codexSubagentMetadata(inTranscriptPath: $0)
                }
                let metadata = transcriptMetadata ?? databaseRecords[agentId]?.metadata
                if child.sessionTitle == nil {
                    child.sessionTitle = metadata?.agentNickname ?? subagent.toolDescription ?? subagent.agentType
                }
                if child.transcriptPath == nil {
                    if let statePath = databaseRecords[agentId]?.transcriptPath,
                       FileManager.default.fileExists(atPath: statePath) {
                        child.transcriptPath = statePath
                    } else if let cwd = parent.session.cwd {
                        let base = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".codex/sessions").path
                        child.transcriptPath = Self.findRecentCodexSession(
                            base: base,
                            cwd: cwd,
                            after: parent.session.cliStartTime,
                            fm: .default
                        )
                    }
                }
                if let transcriptPath = child.transcriptPath {
                    let (model, messages) = Self.readRecentFromCodexTranscript(path: transcriptPath)
                    child.model = child.model ?? model
                    if !messages.isEmpty {
                        child.recentMessages = messages
                        child.lastUserPrompt = messages.last(where: \.isUser)?.text
                        child.lastAssistantMessage = messages.last(where: { !$0.isUser })?.text
                    }
                }

                sessions[childKey] = child
                refreshProviderTitle(for: childKey, providerSessionId: agentId)
                attachTranscriptTailerIfNeeded(sessionId: childKey)
                tryMonitorSession(childKey)
                sessions[parent.sessionId]?.subagents.removeValue(forKey: agentId)
                if subagent.status != .idle {
                    activeSessionId = childKey
                }
                didMutate = true
            }
            if sessions[parent.sessionId]?.subagents.isEmpty == true {
                clearSubagentProjection(fromParentSession: parent.sessionId)
            }
        }

        return didMutate
    }

    @discardableResult
    private func hideMergedCodexSubagents() -> Bool {
        var didMutate = false
        for (sessionId, session) in sessions where session.source == "codex" && !session.subagents.isEmpty {
            sessions[sessionId]?.subagents.removeAll()
            clearSubagentProjection(fromParentSession: sessionId)
            didMutate = true
        }
        return didMutate
    }

    private func clearSubagentProjection(fromParentSession sessionId: String) {
        guard sessions[sessionId]?.currentTool == "Agent" else { return }
        sessions[sessionId]?.currentTool = nil
        sessions[sessionId]?.toolDescription = nil
        if sessions[sessionId]?.status == .running {
            sessions[sessionId]?.status = .processing
        }
    }

    private func routeDiscoveredSubsessionIfNeeded(_ info: DiscoveredSession) -> Bool {
        guard info.source == "codex",
              let parentSessionId = info.parentSessionId,
              !parentSessionId.isEmpty else {
            return false
        }

        let mode = Self.currentPluginSessionMode()
        guard mode == "hide" || mode == "merge" else {
            return false
        }

        if mode == "hide" {
            if sessions[info.sessionId] != nil {
                removeSession(info.sessionId)
            }
            return true
        }

        guard let parentKey = findCodexParentSessionId(
            providerSessionId: parentSessionId,
            childTermBundleId: info.termBundleId
        ) else {
            return false
        }

        if sessions[info.sessionId] != nil {
            removeSession(info.sessionId)
        }

        let providerSessionId = info.providerSessionId ?? info.sessionId

        if info.subagentStatus?.lowercased() == "closed" || info.status == .idle {
            if sessions[parentKey]?.subagents.removeValue(forKey: providerSessionId) != nil,
               sessions[parentKey]?.subagents.isEmpty == true {
                clearSubagentProjection(fromParentSession: parentKey)
            }
            return true
        }

        let agentType = info.agentType ?? info.agentNickname ?? "Agent"
        var subagent = sessions[parentKey]?.subagents[providerSessionId]
            ?? SubagentState(agentId: providerSessionId, agentType: agentType)
        subagent.status = .running
        subagent.toolDescription = info.agentNickname
        subagent.lastActivity = info.modifiedAt
        sessions[parentKey]?.subagents[providerSessionId] = subagent

        if sessions[parentKey]?.status != .waitingApproval && sessions[parentKey]?.status != .waitingQuestion {
            sessions[parentKey]?.status = .running
            sessions[parentKey]?.currentTool = "Agent"
            sessions[parentKey]?.toolDescription = info.agentNickname ?? agentType
        }
        // Read before the assignment: writing `sessions[...]` while the RHS also
        // reads it overlaps a modify with a read access and traps at runtime.
        let previousParentActivity = sessions[parentKey]?.lastActivity ?? .distantPast
        sessions[parentKey]?.lastActivity = max(previousParentActivity, info.modifiedAt)
        activeSessionId = parentKey
        return true
    }

    func stopSessionDiscovery() {
        tearDownProjectsWatcher()
        rotationTimer?.invalidate()
        rotationTimer = nil
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        saveTimer?.invalidate()
        saveTimer = nil
        discoveryScanTask?.cancel()
        discoveryScanTask = nil
        pendingDiscoveryRescan = false
        codexDesktopDiscoveryScanTask?.cancel()
        codexDesktopDiscoveryScanTask = nil
        lastCodexDesktopDiscoveryPollAt = nil
        for key in Array(processMonitors.keys) { stopMonitor(key) }
    }

    /// Stops the FSEvents watcher on the main queue so Stop/Invalidate cannot
    /// race a queued callback. Safe to call from `deinit` (any thread).
    nonisolated private func tearDownProjectsWatcher() {
        let run = { [self] in tearDownProjectsWatcherAssumingMain() }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.sync(execute: run)
        }
    }

    /// FSEvents teardown; caller must already be on the main queue.
    nonisolated private func tearDownProjectsWatcherAssumingMain() {
        // Flip cancel before stopping so any already-queued callback no-ops
        // instead of touching a dying AppState / freed box.
        projectsWatcherBox?.cancel()
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsEventStream = nil
        }
        let box = projectsWatcherBox
        projectsWatcherBox = nil
        // Keep the box alive until after previously queued main-queue
        // callbacks drain (Invalidate does not flush them).
        if let box {
            DispatchQueue.main.async { _ = box }
        }
    }

    deinit {
        // Must not use MainActor.assumeIsolated: async callers (notably XCTest)
        // can release AppState off the main actor via ARC. Weak-boxed FSEvents
        // + main-synced Timer/FSEvents teardown keep discovery crash-free.
        tearDownMainThreadResources()
        discoveryScanTask?.cancel()
        codexDesktopDiscoveryScanTask?.cancel()
        codexAppServerReconnectTask?.cancel()
        for (_, monitor) in processMonitors {
            monitor.source.cancel()
        }
    }

    /// Invalidates main-run-loop Timers and the FSEvents watcher in one main-queue
    /// hop. Safe from any thread so `deinit` stays uniformly main-safe.
    nonisolated private func tearDownMainThreadResources() {
        let teardown = { [self] in
            rotationTimer?.invalidate()
            rotationTimer = nil
            cleanupTimer?.invalidate()
            cleanupTimer = nil
            saveTimer?.invalidate()
            saveTimer = nil
            tearDownProjectsWatcherAssumingMain()
        }
        if Thread.isMainThread {
            teardown()
        } else {
            DispatchQueue.main.sync(execute: teardown)
        }
    }

    struct DiscoveredSession {
        let sessionId: String
        let cwd: String
        let tty: String?
        let model: String?
        let pid: pid_t?
        let modifiedAt: Date
        let recentMessages: [ChatMessage]
        var source: String = "claude"
        /// Absolute path to the JSONL transcript this session was discovered from.
        /// When non-nil and the session is still live, AppState registers a JSONLTailer
        /// so incremental assistant appends reach the UI without another full scan.
        var transcriptPath: String? = nil
        var parentSessionId: String? = nil
        var subagentStatus: String? = nil
        var agentType: String? = nil
        var agentNickname: String? = nil
        /// Optional status inferred by a provider-specific discovery path.
        var status: AgentStatus? = nil
        /// Native host bundle when discovery represents an app session.
        var termBundleId: String? = nil
        /// Provider's raw thread ID when the tracking key uses a namespace prefix.
        var providerSessionId: String? = nil
    }

    /// Find running `claude` processes, match to transcript files, extract recent messages
    private nonisolated static func findActiveClaudeSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        // Step 1: find running claude processes using native APIs
        let claudePids = findClaudePids(candidatePids: candidatePids)
        guard !claudePids.isEmpty else { return [] }

        let fm = FileManager.default
        let processes = claudePids.compactMap { pid -> ClaudeDiscoveryProcess? in
            guard let cwd = getCwd(for: pid), !cwd.isEmpty else { return nil }
            // Skip subagent worktrees — they are child tasks, not independent sessions
            if cwd.contains("/.claude/worktrees/agent-") || cwd.contains("/.git/worktrees/agent-") {
                return nil
            }
            // Process start time filters stale transcript files
            return ClaudeDiscoveryProcess(pid: pid, cwd: cwd, startTime: getProcessStartTime(pid))
        }

        let root = ClaudeConfigPaths.configDir()
        var claimed = Set<String>()
        return processes.compactMap { process in
            guard let session = claudeSession(for: process, root: root, excluding: claimed, fm: fm) else {
                return nil
            }
            claimed.insert(session.sessionId)
            return session
        }
    }

    struct ClaudeDiscoveryProcess {
        let pid: pid_t
        let cwd: String
        let startTime: Date?
    }

    /// One claude process → its CWD → the single most recent .jsonl under `root`.
    private nonisolated static func claudeSession(
        for process: ClaudeDiscoveryProcess,
        root: String,
        excluding claimed: Set<String>,
        fm: FileManager
    ) -> DiscoveredSession? {
        let projectPath = "\(root)/projects/\(process.cwd.claudeProjectDirEncoded())"
        guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { return nil }

        // Find the most recently modified .jsonl that was written AFTER this process started
        var bestFile: String?
        var bestDate = Date.distantPast
        for file in files where file.hasSuffix(".jsonl") {
            let fullPath = "\(projectPath)/\(file)"
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               let modified = attrs[.modificationDate] as? Date,
               modified > bestDate {
                // Skip files from old sessions: must be modified after process started
                if let start = process.startTime, modified < start.addingTimeInterval(-10) {
                    continue
                }
                bestDate = modified
                bestFile = file
            }
        }

        guard let file = bestFile else { return nil }

        // Skip stale transcripts: only show sessions active within last 5 minutes.
        // When processStart is unknown (proc_pidinfo failed), use a tighter 30s window
        // to avoid resurrecting zombie sessions from stale transcript files.
        let freshnessLimit: TimeInterval = process.startTime != nil ? -300 : -30
        if bestDate.timeIntervalSinceNow < freshnessLimit { return nil }

        let sessionId = String(file.dropLast(6))
        guard !claimed.contains(sessionId) else { return nil }

        let fullPath = "\(projectPath)/\(file)"
        let (model, messages) = readRecentFromTranscript(path: fullPath)

        return DiscoveredSession(
            sessionId: sessionId,
            cwd: process.cwd,
            tty: nil,
            model: model,
            pid: process.pid,
            modifiedAt: bestDate,
            recentMessages: messages,
            transcriptPath: fullPath
        )
    }

    private nonisolated static func allProcessIds() -> [pid_t] {
        var bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bufferSize) / MemoryLayout<pid_t>.size + 10)
        bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        let count = Int(bufferSize) / MemoryLayout<pid_t>.size
        return Array(pids.prefix(count)).filter { $0 > 0 }
    }

    private nonisolated static func executablePath(for pid: pid_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard len > 0 else { return nil }
        return String(cString: pathBuffer)
    }

    private nonisolated static func findPids(
        matchingPathSubstrings pathSubstrings: [String],
        argSubstrings: [String] = [],
        candidatePids: [pid_t]? = nil
    ) -> [pid_t] {
        let loweredPaths = pathSubstrings.map { $0.lowercased() }
        let loweredArgs = argSubstrings.map { $0.lowercased() }
        guard !loweredPaths.isEmpty || !loweredArgs.isEmpty else { return [] }

        var matched: [pid_t] = []
        for pid in candidatePids ?? allProcessIds() {
            guard let path = executablePath(for: pid)?.lowercased() else { continue }
            if loweredPaths.contains(where: { path.contains($0) }) {
                matched.append(pid)
                continue
            }
            guard !loweredArgs.isEmpty,
                  let args = getProcessArgs(pid)?.map({ $0.lowercased() }) else { continue }
            if args.contains(where: { arg in loweredArgs.contains(where: { arg.contains($0) }) }) {
                matched.append(pid)
            }
        }
        return matched
    }

    /// Get PIDs of running Claude Code processes
    /// Claude's binary is named by version (e.g. "2.1.91") under ~/.local/share/claude/versions/
    private nonisolated static func findClaudePids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        let claudeVersionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/claude/versions").path

        var claudePids: [pid_t] = []

        for pid in candidatePids ?? allProcessIds() {
            guard let path = executablePath(for: pid) else { continue }
            // Match processes whose executable is under claude's versions directory
            if path.hasPrefix(claudeVersionsDir) {
                claudePids.append(pid)
            }
        }
        return claudePids
    }

    /// Google Antigravity (Gemini-based IDE/CLI, #215). The actionable agent is the
    /// `agy` CLI (pypi google-antigravity) launched from the IDE's integrated
    /// terminal; the IDE itself is Antigravity.app (com.google.antigravity).
    /// We match the IDE app *only* via the Google-specific .app path component to
    /// avoid colliding with the existing "antigravity" Claude-fork CLI (which lives
    /// under ~/.antigravity, never in an .app named exactly "antigravity").
    private nonisolated static func findGoogleAntigravityPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/antigravity.app/contents/macos/",
                "/bin/agy",
            ],
            argSubstrings: [
                "/google-antigravity/",
                "/antigravity-cli/",
                "/bin/agy",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func md5Hash(of string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func findOpenCodePids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/opencode.app/contents/macos/opencode",
                "/opencode.app/contents/macos/opencode-cli",
                "/.opencode/bin/opencode",
            ],
            candidatePids: candidatePids
        ).filter { pid in
            // OpenCode 2's shared background service is the same executable as
            // the TUI and inherits the first client's cwd, so a cwd match can
            // land on it. It is not a session's process: it outlives the client
            // that spawned it, and once reparented to launchd the orphan sweep
            // would SIGTERM it — every session with it (#332).
            guard let args = getProcessArgs(pid) else { return true }
            return !isOpenCodeSharedService(arguments: args)
        }
    }

    /// `opencode serve --service` — OpenCode 2's per-user shared server.
    nonisolated static func isOpenCodeSharedService(arguments: [String]) -> Bool {
        arguments.contains("serve") && arguments.contains("--service")
    }

    /// Get the current working directory of a process using proc_pidinfo
    private nonisolated static func getCwd(for pid: pid_t) -> String? {
        var pathInfo = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &pathInfo, Int32(size))
        guard ret > 0 else { return nil }
        return withUnsafePointer(to: pathInfo.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    /// Get the start time of a process using proc_pidinfo
    private nonisolated static func getProcessStartTime(_ pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard ret > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    private nonisolated static func isSubagentWorktree(_ cwd: String) -> Bool {
        cwd.contains("/.claude/worktrees/agent-") || cwd.contains("/.git/worktrees/agent-")
    }

    private nonisolated static func findMostRecentJSONLFile(
        in directory: String,
        after processStart: Date?,
        fm: FileManager
    ) -> (path: String, modified: Date)? {
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return nil }

        var bestPath: String?
        var bestDate = Date.distantPast
        for file in files where file.hasSuffix(".jsonl") {
            let fullPath = "\(directory)/\(file)"
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modified = attrs[.modificationDate] as? Date,
                  modified > bestDate else { continue }
            if let start = processStart, modified < start.addingTimeInterval(-10) {
                continue
            }
            bestPath = fullPath
            bestDate = modified
        }

        guard let bestPath else { return nil }
        return (bestPath, bestDate)
    }

    // MARK: - OpenCode

    nonisolated static func openCodeDatabasePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db").path
    }

    private nonisolated static func findActiveOpenCodeSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        findActiveOpenCodeStoreSessions(
            pids: findOpenCodePids(candidatePids: candidatePids),
            dbPath: openCodeDatabasePath(),
            source: "opencode",
            sessionIdPrefix: "",
            rootSessionsOnly: false
        )
    }

    private nonisolated static func findActiveOpenCodeStoreSessions(
        pids: [pid_t],
        dbPath: String,
        source: String,
        sessionIdPrefix: String,
        rootSessionsOnly: Bool
    ) -> [DiscoveredSession] {
        guard !pids.isEmpty else { return [] }
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

        return withSQLiteDatabase(at: dbPath) { db in
            var results: [DiscoveredSession] = []
            var seenSessionIds: Set<String> = []

            for pid in pids {
                guard let cwd = getCwd(for: pid), !cwd.isEmpty, !isSubagentWorktree(cwd) else { continue }
                let processStart = getProcessStartTime(pid)
                guard let session = findRecentOpenCodeSession(
                    in: db, cwd: cwd, after: processStart, rootSessionsOnly: rootSessionsOnly
                ) else { continue }
                guard !seenSessionIds.contains(session.sessionId) else { continue }
                seenSessionIds.insert(session.sessionId)

                let (model, messages) = readRecentFromOpenCodeSession(db: db, sessionId: session.sessionId)
                results.append(DiscoveredSession(
                    sessionId: sessionIdPrefix + session.sessionId,
                    cwd: cwd,
                    tty: nil,
                    model: model,
                    pid: pid,
                    modifiedAt: session.modifiedAt,
                    recentMessages: messages,
                    source: source
                ))
            }

            return results
        } ?? []
    }

    nonisolated static func withSQLiteDatabase<T>(
        at path: String,
        body: (OpaquePointer) -> T?
    ) -> T? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close_v2(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 1000)
        defer { sqlite3_close_v2(db) }
        return body(db)
    }

    private nonisolated static func prepareSQLiteStatement(db: OpaquePointer, sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        return statement
    }

    private nonisolated static func sqliteTableColumns(
        db: OpaquePointer,
        tableName: String
    ) -> Set<String> {
        guard tableName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              let statement = prepareSQLiteStatement(
                db: db,
                sql: "PRAGMA table_info(\(tableName));"
              ) else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqliteColumnString(statement, index: 1) {
                columns.insert(name)
            }
        }
        return columns
    }

    private nonisolated static func bindSQLiteText(_ text: String, to statement: OpaquePointer, index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = text.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
    }

    private nonisolated static func sqliteColumnString(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: UnsafeRawPointer(value).assumingMemoryBound(to: CChar.self))
    }

    /// `rootSessionsOnly` skips child sessions (`parent_id` set): MiMo Code
    /// spawns subagent sessions in the same directory, and while one runs it
    /// is the most recently updated row — but it is never the CLI's own.
    nonisolated static func findRecentOpenCodeSession(
        in db: OpaquePointer,
        cwd: String,
        after processStart: Date?,
        rootSessionsOnly: Bool = false
    ) -> (sessionId: String, modifiedAt: Date)? {
        let rootFilter = rootSessionsOnly ? "AND parent_id IS NULL" : ""
        let sql = """
            SELECT id, time_updated
            FROM session
            WHERE time_archived IS NULL
              \(rootFilter)
              AND (
                directory = ?
                OR EXISTS (
                    SELECT 1
                    FROM message m
                    WHERE m.session_id = session.id
                      AND json_extract(m.data, '$.path.cwd') = ?
                )
              )
            ORDER BY time_updated DESC
            LIMIT 20;
            """
        guard let statement = prepareSQLiteStatement(db: db, sql: sql) else { return nil }
        defer { sqlite3_finalize(statement) }

        bindSQLiteText(cwd, to: statement, index: 1)
        bindSQLiteText(cwd, to: statement, index: 2)

        let minUpdatedAtMs = processStart.map { Int64($0.timeIntervalSince1970 * 1000) - 10_000 }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sessionId = sqliteColumnString(statement, index: 0) else { continue }
            let updatedAtMs = sqlite3_column_int64(statement, 1)
            if let minUpdatedAtMs, updatedAtMs < minUpdatedAtMs { continue }
            let modifiedAt = Date(timeIntervalSince1970: TimeInterval(updatedAtMs) / 1000)
            return (sessionId, modifiedAt)
        }
        return nil
    }

    private nonisolated static func readRecentFromOpenCodeSession(
        db: OpaquePointer,
        sessionId: String
    ) -> (String?, [ChatMessage]) {
        var model: String?

        if let messageStatement = prepareSQLiteStatement(
            db: db,
            sql: """
                SELECT data
                FROM message
                WHERE session_id = ?
                ORDER BY time_updated DESC
                LIMIT 12;
                """
        ) {
            defer { sqlite3_finalize(messageStatement) }
            bindSQLiteText(sessionId, to: messageStatement, index: 1)
            while sqlite3_step(messageStatement) == SQLITE_ROW {
                guard model == nil,
                      let data = sqliteColumnString(messageStatement, index: 0),
                      let jsonData = data.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }
                model = json["modelID"] as? String
                if model == nil,
                   let modelInfo = json["model"] as? [String: Any] {
                    model = modelInfo["modelID"] as? String
                }
            }
        }

        var seenMessageIds: Set<String> = []
        var combined: [(Int64, ChatMessage)] = []
        if let partStatement = prepareSQLiteStatement(
            db: db,
            sql: """
                SELECT p.message_id, json_extract(m.data, '$.role'), p.time_created, p.data
                FROM part p
                JOIN message m ON m.id = p.message_id
                WHERE p.session_id = ?
                ORDER BY p.time_created DESC
                LIMIT 80;
                """
        ) {
            defer { sqlite3_finalize(partStatement) }
            bindSQLiteText(sessionId, to: partStatement, index: 1)
            while sqlite3_step(partStatement) == SQLITE_ROW {
                guard let messageId = sqliteColumnString(partStatement, index: 0),
                      !seenMessageIds.contains(messageId),
                      let role = sqliteColumnString(partStatement, index: 1),
                      let data = sqliteColumnString(partStatement, index: 3),
                      let jsonData = data.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      json["type"] as? String == "text",
                      let text = json["text"] as? String, !text.isEmpty else { continue }

                let isUser = role == "user"
                guard isUser || role == "assistant" else { continue }

                seenMessageIds.insert(messageId)
                combined.append((sqlite3_column_int64(partStatement, 2), ChatMessage(isUser: isUser, text: text)))
            }
        }

        combined.sort { $0.0 < $1.0 }
        return (model, Array(combined.suffix(3).map { $0.1 }))
    }

    // MARK: - Codex Session Discovery

    /// Find running Codex processes.
    /// Checks both executable path (Desktop app) and command-line args (npm/Homebrew: node script).
    nonisolated static func isCodexExecutablePath(_ path: String) -> Bool {
        let executableURL = URL(fileURLWithPath: path).standardizedFileURL
        let lowerPath = executableURL.path.lowercased()
        let resourceSuffix = "/contents/resources/codex"
        guard lowerPath.hasSuffix(resourceSuffix) else { return false }

        let appURL = executableURL
            .deletingLastPathComponent() // Resources
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // *.app
        return isCodexHostAppBundle(appURL)
    }

    /// The Codex binary newer ChatGPT releases bundle in place of
    /// `Contents/Resources/codex`. Desktop's app-server, ChatGPT's terminal
    /// launcher (`codex-cli/bin/codex`) and its cloud `exec-server` all run
    /// this one file, so the path says Codex, not Desktop.
    nonisolated static func isBundledCodexCLIPath(_ path: String) -> Bool {
        let executableURL = URL(fileURLWithPath: path).standardizedFileURL
        let suffix = "/" + bundledCodexCLIRelativePath.lowercased()
        guard executableURL.path.lowercased().hasSuffix(suffix) else { return false }
        var appURL = executableURL
        for _ in bundledCodexCLIRelativePath.split(separator: "/") {
            appURL.deleteLastPathComponent()
        }
        return isCodexHostAppBundle(appURL)
    }

    private nonisolated static func isCodexHostAppBundle(_ appURL: URL) -> Bool {
        // Since Codex was folded into ChatGPT Desktop, the same com.openai.codex
        // bundle can now be installed as ChatGPT.app instead of Codex.app. Read
        // the bundle identifier first so future app renames continue to work.
        if Bundle(url: appURL)?.bundleIdentifier == AppState.codexAppBundleId {
            return true
        }

        // Keep the legacy path check for synthetic/test bundles without an
        // Info.plist and for older installations whose bundle cannot be read.
        let appName = appURL.deletingPathExtension().lastPathComponent.lowercased()
        return appName == "codex" || appName == "chatgpt"
    }

    /// Codex Desktop's shared app-server is launched with `/` as its cwd. Its
    /// rollout metadata contains the project cwd, so desktop discovery must
    /// use that value instead of comparing every transcript to `/`.
    nonisolated static func codexDiscoveryUsesTranscriptCwd(processCwd: String?) -> Bool {
        guard let processCwd, !processCwd.isEmpty else { return true }
        return processCwd == "/"
    }

    /// Codex Desktop currently invokes some hooks without a payload, or with
    /// the shared app-server's root cwd. Those events contain no session data
    /// and would overwrite a session discovered from its rollout transcript.
    nonisolated static func isCodexPlaceholderHook(
        source: String?,
        cwd: String?,
        hasTranscriptPath: Bool
    ) -> Bool {
        guard source?.lowercased() == "codex", !hasTranscriptPath else { return false }
        return cwd == nil || cwd?.trimmingCharacters(in: .whitespacesAndNewlines) == "/"
    }

    /// Keep all three Codex Desktop discovery channels on one stable tracking
    /// key while leaving CLI sessions in the provider's raw namespace.
    nonisolated static func codexDiscoveryIdentity(
        rawSessionId: String,
        isDesktop: Bool
    ) -> CodexDiscoveryIdentity {
        if isDesktop {
            return CodexDiscoveryIdentity(
                sessionId: codexAppSessionPrefix + rawSessionId,
                providerSessionId: rawSessionId,
                termBundleId: codexAppBundleId
            )
        }
        return CodexDiscoveryIdentity(
            sessionId: rawSessionId,
            providerSessionId: nil,
            termBundleId: nil
        )
    }

    /// Upgrade pre-namespace persisted Desktop hook cards without touching raw
    /// Codex CLI ids. `termBundleId` is the reliable discriminator retained by
    /// #267-era snapshots.
    nonisolated static func canonicalRestoredCodexSessionId(
        sessionId: String,
        source: String,
        providerSessionId: String?,
        termBundleId: String?
    ) -> String {
        guard source == "codex", termBundleId == codexAppBundleId else {
            return sessionId
        }
        if sessionId.hasPrefix(codexAppSessionPrefix) {
            return sessionId
        }
        let rawId = providerSessionId?.isEmpty == false ? providerSessionId! : sessionId
        return codexAppSessionPrefix + rawId
    }

    /// Read only the rollout's first `session_meta` row to distinguish Desktop
    /// rollouts from CLI rollouts when both exist under `~/.codex/sessions`.
    /// Unknown future shapes remain eligible for the owning process as a
    /// best-effort fallback instead of being dropped.
    nonisolated static func codexTranscriptOrigin(path: String) -> CodexTranscriptOrigin {
        guard let firstLine = readFirstLine(path: path),
              let data = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["payload"] as? [String: Any] else {
            return .unknown
        }

        let originator = (payload["originator"] as? String)?.lowercased() ?? ""
        let source = (payload["source"] as? String)?.lowercased() ?? ""
        if originator.contains("desktop") {
            return .desktop
        }
        // Codex records every app-server client under `vscode`/`appServer`,
        // and a spawned thread keeps its parent's originator under an object
        // source. A client that names itself something other than Desktop
        // (Claude Code's Codex plugin sends "Claude Code") runs its own
        // `codex app-server`, so the rollout belongs to that process like a
        // CLI one.
        let isAppServerSource = source == "vscode" || source == "appserver"
        let isSubagentSource = payload["source"] is [String: Any]
        if !originator.isEmpty, isAppServerSource || isSubagentSource {
            return .cli
        }
        if isAppServerSource {
            return .desktop
        }
        if originator.contains("cli") || source == "cli" || source == "exec" {
            return .cli
        }
        return .unknown
    }

    private nonisolated static func findCodexPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findCodexProcesses(candidatePids: candidatePids).map(\.pid)
    }

    /// Running Codex processes discovery maps rollouts to, and whether each
    /// is Codex Desktop's shared app-server.
    nonisolated static func findCodexProcesses(candidatePids: [pid_t]? = nil) -> [(pid: pid_t, isDesktop: Bool)] {
        var processes: [(pid: pid_t, isDesktop: Bool)] = []

        for pid in candidatePids ?? allProcessIds() {
            guard let path = executablePath(for: pid) else { continue }
            let pathLower = path.lowercased()

            // Match 1: Codex Desktop app (native binary). The executable may
            // live under Codex.app or ChatGPT.app depending on the release.
            if isCodexExecutablePath(path) {
                processes.append((pid, true))
                continue
            }

            // Match 2: the binary newer ChatGPT releases bundle, shared by
            // Desktop's app-server and Codex CLI; argv and parent tell them apart.
            if isBundledCodexCLIPath(path) {
                if let role = bundledCodexProcessRole(pid: pid, executablePath: path) {
                    processes.append((pid, role == .desktopHost))
                }
                continue
            }

            // Match 3: npm/Homebrew install — node running @openai/codex script.
            // proc_pidpath returns the node binary, so check command-line args instead.
            if pathLower.hasSuffix("/node") {
                if let args = getProcessArgs(pid),
                   args.contains(where: { $0.contains("@openai/codex") || $0.contains("openai-codex") }) {
                    processes.append((pid, false))
                }
            }
        }
        return processes
    }

    private nonisolated static func bundledCodexProcessRole(pid: pid_t, executablePath path: String) -> CodexProcessRole? {
        let parent = parentPid(of: pid)
        // CodeIsland's own app-server client runs this binary too, from `/`;
        // as a session process it would claim every CLI rollout.
        if parent == getpid() { return nil }

        var ancestry = [ProcessAncestor(pid: pid, executablePath: path, arguments: getProcessArgs(pid) ?? [])]
        if let parent, let parentPath = executablePath(for: parent) {
            ancestry.append(ProcessAncestor(
                pid: parent,
                executablePath: parentPath,
                bundleIdentifier: ProcessAncestry.outermostAppBundlePath(forExecutable: parentPath)
                    .flatMap { Bundle(path: $0)?.bundleIdentifier }
            ))
        }
        return CLIProcessResolver.codexBundledProcessRole(ancestry: ancestry)
    }

    /// Get command-line arguments for a process via sysctl KERN_PROCARGS2.
    private nonisolated static func getProcessArgs(_ pid: pid_t) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        // First 4 bytes = argc (as int32)
        guard size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0, argc < 256 else { return nil }

        // Skip past argc + executable path + padding nulls to reach argv
        var offset = MemoryLayout<Int32>.size
        // Skip executable path
        while offset < size && buffer[offset] != 0 { offset += 1 }
        // Skip null padding
        while offset < size && buffer[offset] == 0 { offset += 1 }

        // Parse null-terminated argv strings
        var args: [String] = []
        var argStart = offset
        for _ in 0..<argc {
            while offset < size && buffer[offset] != 0 { offset += 1 }
            if offset > argStart {
                args.append(String(bytes: buffer[argStart..<offset], encoding: .utf8) ?? "")
            }
            offset += 1
            argStart = offset
        }
        return args
    }

    /// Scan a rollout backwards in chunks until the latest lifecycle marker is
    /// found. This avoids both a full-file read and a fixed-tail limit while
    /// reusing `JSONLTailer`'s canonical Codex event interpretation.
    nonisolated static func latestCodexTurnStatus(
        path: String,
        chunkSize: UInt64 = 256 * 1024,
        maxBytesToScan: UInt64 = 64 * 1024 * 1024,
        maxLineBytes: Int = 4 * 1024 * 1024
    ) -> ConversationTurnStatus? {
        guard chunkSize > 0, maxBytesToScan > 0, maxLineBytes > 0 else { return nil }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let lowerBound = fileSize > maxBytesToScan ? fileSize - maxBytesToScan : 0
        var cursor = fileSize
        var leadingFragment = Data()
        var discardingOversizedLine = false

        while cursor > lowerBound {
            let readSize = min(cursor - lowerBound, chunkSize)
            cursor -= readSize
            handle.seek(toFileOffset: cursor)
            let chunk = handle.readData(ofLength: Int(readSize))
            var combined: Data
            if discardingOversizedLine {
                // We are walking backwards through one over-budget line. Drop
                // its bytes until the previous newline, then resume with older
                // complete lines instead of retaining/copying an unbounded blob.
                guard let newline = chunk.lastIndex(of: 0x0A) else { continue }
                combined = Data(chunk[...newline])
                discardingOversizedLine = false
            } else {
                combined = chunk
                combined.append(leadingFragment)
            }

            var lines: [Data] = []
            var lineStart = combined.startIndex
            for index in combined.indices where combined[index] == 0x0A {
                lines.append(Data(combined[lineStart..<index]))
                lineStart = combined.index(after: index)
            }
            lines.append(Data(combined[lineStart..<combined.endIndex]))
            if cursor > lowerBound, !lines.isEmpty {
                let fragment = lines.removeFirst()
                if fragment.count > maxLineBytes {
                    leadingFragment.removeAll(keepingCapacity: true)
                    discardingOversizedLine = true
                } else {
                    leadingFragment = fragment
                }
            } else {
                leadingFragment.removeAll(keepingCapacity: true)
                // A capped scan begins in the middle of an unknown line. Never
                // parse that boundary fragment as if it were complete JSON.
                if lowerBound > 0, !lines.isEmpty {
                    lines.removeFirst()
                }
            }

            for line in lines.reversed()
            where !line.isEmpty && line.count <= maxLineBytes {
                if let status = codexTurnStatus(fromCompleteLine: line) {
                    return status
                }
            }
        }

        return nil
    }

    private nonisolated static func codexTurnStatus(fromCompleteLine line: Data) -> ConversationTurnStatus? {
        var newlineTerminated = line
        newlineTerminated.append(0x0A)
        return JSONLTailer.latestTurnStatus(in: newlineTerminated)
    }

    /// Load recently touched Codex Desktop threads from Codex's own state DB.
    /// Desktop app-server processes use `/` as CWD in current releases, making
    /// the process-to-project matcher insufficient on its own.
    nonisolated static func recentCodexDesktopThreadRecords(
        statePath overrideStatePath: String? = nil,
        now: Date = Date(),
        freshnessWindow: TimeInterval = 600,
        completionSettleWindow: TimeInterval = 30,
        fileManager: FileManager = .default
    ) -> [CodexDesktopThreadRecord] {
        let statePath = overrideStatePath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite").path
        // `has_user_event` is not a reliable visibility bit for Desktop threads:
        // current ChatGPT/Codex builds may keep it at 0 while a user turn is
        // actively writing to the rollout. Pull a slightly wider DB candidate
        // window, then enforce the tighter freshness window from DB/file mtimes.
        let candidateWindow = max(freshnessWindow, 60 * 60)
        let cutoff = now.addingTimeInterval(-candidateWindow).timeIntervalSince1970

        return withSQLiteDatabase(at: statePath) { db in
            let columns = sqliteTableColumns(db: db, tableName: "threads")
            let requiredColumns: Set<String> = [
                "id", "rollout_path", "cwd", "archived", "source",
            ]
            guard requiredColumns.isSubset(of: columns) else { return [] }

            let updatedAtExpression: String
            if columns.contains("updated_at_ms"), columns.contains("updated_at") {
                updatedAtExpression = "COALESCE(NULLIF(updated_at_ms, 0) / 1000.0, updated_at)"
            } else if columns.contains("updated_at_ms") {
                updatedAtExpression = "updated_at_ms / 1000.0"
            } else if columns.contains("updated_at") {
                updatedAtExpression = "updated_at"
            } else {
                return []
            }
            let modelExpression = columns.contains("model") ? "model" : "NULL"
            let spawnColumns = sqliteTableColumns(db: db, tableName: "thread_spawn_edges")
            let hasSpawnStatus = Set(["child_thread_id", "status"]).isSubset(of: spawnColumns)
            let spawnJoin = hasSpawnStatus
                ? "LEFT JOIN thread_spawn_edges edge ON edge.child_thread_id = thread.id"
                : ""
            let spawnStatusExpression = hasSpawnStatus ? "edge.status" : "NULL"

            guard let statement = prepareSQLiteStatement(
                db: db,
                sql: """
                    SELECT thread.id, thread.rollout_path, thread.cwd,
                           \(updatedAtExpression), \(modelExpression),
                           \(spawnStatusExpression), thread.source
                    FROM threads AS thread
                    \(spawnJoin)
                    WHERE thread.archived = 0
                      AND \(updatedAtExpression) >= ?
                      AND (
                        thread.source = 'vscode'
                        OR thread.source = 'appServer'
                        OR thread.source LIKE '{"subagent"%'
                      )
                      ORDER BY \(updatedAtExpression) DESC
                      LIMIT 50;
                    """
            ) else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, cutoff)

            var records: [CodexDesktopThreadRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let sessionId = sqliteColumnString(statement, index: 0),
                      let transcriptPath = sqliteColumnString(statement, index: 1),
                      let cwd = sqliteColumnString(statement, index: 2),
                      fileManager.fileExists(atPath: transcriptPath) else { continue }
                // JSON `source` rows can also belong to a concurrent Codex CLI
                // subagent. Never re-key an explicitly CLI-origin rollout into
                // the Desktop namespace merely because the Desktop host is open.
                let transcriptOrigin = codexTranscriptOrigin(path: transcriptPath)
                let databaseSource = sqliteColumnString(statement, index: 6) ?? ""
                if databaseSource.hasPrefix("{\"subagent") {
                    // JSON source alone does not identify the owning surface.
                    // Require positive Desktop provenance before namespacing it.
                    guard transcriptOrigin == .desktop else { continue }
                } else {
                    guard transcriptOrigin != .cli else { continue }
                }

                let dbUpdatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                let fileModifiedAt = (try? fileManager.attributesOfItem(atPath: transcriptPath))?[.modificationDate] as? Date
                let modifiedAt = max(dbUpdatedAt, fileModifiedAt ?? dbUpdatedAt)
                guard modifiedAt >= now.addingTimeInterval(-freshnessWindow) else { continue }

                let dbModel = sqliteColumnString(statement, index: 4)
                let (transcriptModel, messages) = readRecentFromCodexTranscript(path: transcriptPath)
                let turnStatus = latestCodexTurnStatus(path: transcriptPath)
                let isFresh = now.timeIntervalSince(modifiedAt) <= 300
                let isActive = isFresh && turnStatus == .processing
                if !isActive,
                   now.timeIntervalSince(modifiedAt) > completionSettleWindow {
                    continue
                }

                records.append(CodexDesktopThreadRecord(
                    sessionId: sessionId,
                    cwd: cwd,
                    model: dbModel ?? transcriptModel,
                    modifiedAt: modifiedAt,
                    recentMessages: messages,
                    transcriptPath: transcriptPath,
                    status: isActive ? .processing : .idle,
                    subagentMetadata: codexSubagentMetadata(inTranscriptPath: transcriptPath),
                    subagentStatus: sqliteColumnString(statement, index: 5)
                ))
            }
            return records
        } ?? []
    }

    /// Find active Codex sessions by matching running processes to session files
    private nonisolated static func findActiveCodexSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let codexProcesses = findCodexProcesses(candidatePids: candidatePids)
        guard !codexProcesses.isEmpty else { return [] }

        let processes = codexProcesses.map { process in
            CodexProcessDiscoveryCandidate(
                pid: process.pid,
                cwd: getCwd(for: process.pid),
                startTime: getProcessStartTime(process.pid),
                isDesktop: process.isDesktop
            )
        }

        // A process lands in the first root that has a session for it.
        var results: [DiscoveredSession] = []
        var pending = processes
        for root in codexStateRoots() where !pending.isEmpty {
            let found = discoverCodexSessions(
                processes: pending,
                sessionsBase: "\(root)/sessions",
                statePath: "\(root)/state_5.sqlite"
            ).filter { session in !results.contains { $0.sessionId == session.sessionId } }
            results.append(contentsOf: found)
            // Desktop threads come from the state DB without a pid.
            pending.removeAll { process in
                found.contains { $0.pid == process.pid || ($0.pid == nil && process.isDesktop) }
            }
        }
        return results
    }

    /// Filesystem/state-DB portion of Codex discovery, split from process
    /// inspection so root-CWD fallback and DB degradation can be tested without
    /// relying on live PIDs.
    nonisolated static func discoverCodexSessions(
        processes: [CodexProcessDiscoveryCandidate],
        sessionsBase: String,
        statePath: String,
        now: Date = Date(),
        fileManager fm: FileManager = .default
    ) -> [DiscoveredSession] {
        var results: [DiscoveredSession] = []
        var seenDiscoveryIds: Set<String> = []
        var seenDesktopSessionIds: Set<String> = []
        var claimedUnknownSessionIds: Set<String> = []

        // Prefer the native host for unknown-origin root rollouts. Explicit CLI
        // and Desktop metadata is filtered below, so concurrent modes remain
        // distinct even when they share a project directory.
        let orderedProcesses = processes.sorted {
            $0.isDesktop && !$1.isDesktop
        }
        for process in orderedProcesses {
            let processCwd = process.cwd
            let useTranscriptCwd = codexDiscoveryUsesTranscriptCwd(processCwd: processCwd)
            if !useTranscriptCwd,
               let processCwd,
               isSubagentWorktree(processCwd) {
                continue
            }

            // Codex stores sessions in date-based dirs: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl.
            // A terminal process maps to one cwd; the shared Desktop app-server
            // may own several sessions, so inspect all fresh rollouts instead.
            let candidates = fm.fileExists(atPath: sessionsBase)
                ? findRecentCodexSessions(base: sessionsBase, after: process.startTime, fm: fm)
                : []
            let files: [String]
            if useTranscriptCwd {
                files = candidates.filter { file in
                    switch codexTranscriptOrigin(path: file) {
                    case .desktop: return process.isDesktop
                    case .cli: return !process.isDesktop
                    case .unknown: return true
                    }
                }
            } else if let processCwd {
                files = Array(candidates.filter { file in
                    guard codexSessionMatchesCwd(path: file, cwd: processCwd) else { return false }
                    switch codexTranscriptOrigin(path: file) {
                    case .desktop: return process.isDesktop
                    case .cli: return !process.isDesktop
                    case .unknown: return true
                    }
                }.prefix(1))
            } else {
                files = []
            }

            for file in files {
                let fileName = (file as NSString).lastPathComponent
                let rawSessionId = extractCodexSessionId(from: fileName)
                guard !rawSessionId.isEmpty else { continue }
                let identity = codexDiscoveryIdentity(
                    rawSessionId: rawSessionId,
                    isDesktop: process.isDesktop
                )
                guard !seenDiscoveryIds.contains(identity.sessionId) else { continue }
                let transcriptOrigin = codexTranscriptOrigin(path: file)
                if transcriptOrigin == .unknown,
                   claimedUnknownSessionIds.contains(rawSessionId) {
                    continue
                }

                let modifiedAt = (try? fm.attributesOfItem(atPath: file))?[.modificationDate] as? Date ?? now
                let codexFreshnessLimit: TimeInterval = process.startTime != nil ? -300 : -30
                if modifiedAt.timeIntervalSince(now) < codexFreshnessLimit { continue }

                let transcriptCwd = codexSessionCwd(path: file)
                let sessionCwd = useTranscriptCwd ? transcriptCwd : (transcriptCwd ?? processCwd)
                guard let sessionCwd, !sessionCwd.isEmpty, !isSubagentWorktree(sessionCwd) else { continue }

                let (model, messages) = readRecentFromCodexTranscript(path: file)
                let subagentMetadata = codexSubagentMetadata(inTranscriptPath: file)
                let turnStatus = latestCodexTurnStatus(path: file)

                results.append(DiscoveredSession(
                    sessionId: identity.sessionId,
                    cwd: sessionCwd,
                    tty: nil,
                    model: model,
                    pid: process.pid,
                    modifiedAt: modifiedAt,
                    recentMessages: messages,
                    source: "codex",
                    transcriptPath: file,
                    parentSessionId: subagentMetadata?.parentThreadId,
                    subagentStatus: nil,
                    agentType: subagentMetadata?.agentType,
                    agentNickname: subagentMetadata?.agentNickname,
                    status: turnStatus.map { $0 == .processing ? .processing : .idle },
                    termBundleId: identity.termBundleId,
                    providerSessionId: identity.providerSessionId
                ))
                // Only accepted candidates exclude a matching DB record. A stale
                // or malformed rollout must not hide a valid state-backed thread.
                seenDiscoveryIds.insert(identity.sessionId)
                if transcriptOrigin == .unknown {
                    claimedUnknownSessionIds.insert(rawSessionId)
                }
                if process.isDesktop {
                    seenDesktopSessionIds.insert(rawSessionId)
                }
            }
        }

        // Only actual active subagents need the optional spawn-edge status.
        // Resolve all of them through one read-only SQLite connection; terminal
        // transcript state already wins without consulting the database.
        let activeSubagentIds = Set(results.compactMap { result -> String? in
            guard result.parentSessionId != nil, result.status != .idle else { return nil }
            return result.providerSessionId ?? result.sessionId
        })
        if !activeSubagentIds.isEmpty {
            let spawnRecords = codexSpawnEdgeRecords(
                threadIds: activeSubagentIds,
                statePath: statePath
            )
            for index in results.indices {
                let providerSessionId = results[index].providerSessionId ?? results[index].sessionId
                results[index].subagentStatus = spawnRecords[providerSessionId]?.status
            }
        }

        // Native Codex Desktop / ChatGPT sessions cannot be mapped by process
        // CWD because its app-server runs from `/`. Hydrate recent threads from
        // state_5.sqlite and let transcript activity drive running/idle state.
        if processes.contains(where: { $0.isDesktop }) {
            results.append(contentsOf: findRecentCodexDesktopSessions(
                excluding: seenDesktopSessionIds,
                statePath: statePath,
                now: now,
                fileManager: fm
            ))
        }
        return results
    }

    private nonisolated static func findRecentCodexDesktopSessions(
        excluding excludedSessionIds: Set<String> = [],
        statePath: String? = nil,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [DiscoveredSession] {
        let resolvedStatePath = statePath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite").path

        return recentCodexDesktopThreadRecords(
            statePath: resolvedStatePath,
            now: now,
            fileManager: fileManager
        ).compactMap { record in
            guard !excludedSessionIds.contains(record.sessionId) else { return nil }
            let identity = codexDiscoveryIdentity(rawSessionId: record.sessionId, isDesktop: true)
            return DiscoveredSession(
                sessionId: identity.sessionId,
                cwd: record.cwd,
                tty: nil,
                model: record.model,
                pid: nil,
                modifiedAt: record.modifiedAt,
                recentMessages: record.recentMessages,
                source: "codex",
                transcriptPath: record.transcriptPath,
                parentSessionId: record.subagentMetadata?.parentThreadId,
                subagentStatus: record.subagentStatus,
                agentType: record.subagentMetadata?.agentType,
                agentNickname: record.subagentMetadata?.agentNickname,
                status: record.status,
                termBundleId: identity.termBundleId,
                providerSessionId: identity.providerSessionId
            )
        }
    }

    private nonisolated static func inspectCodexSubagentMetadata(
        inTranscriptPath path: String
    ) -> CodexTranscriptSubagentInspection {
        guard let firstLine = readFirstLine(path: path),
              let data = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "session_meta",
              let payload = json["payload"] as? [String: Any] else {
            return .unavailable
        }

        guard let source = payload["source"] as? [String: Any] else {
            return .root
        }
        let payloadParent = (payload["parent_thread_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // Unit variants (`review`, `compact`, `memory_consolidation`) serialize as
        // a bare string and only record their parent on the payload. Without
        // one there is no spawn edge to fall back to either.
        if let label = source["subagent"] as? String, !label.isEmpty {
            guard let payloadParent else { return .root }
            return .subagent(CodexSubagentMetadata(
                parentThreadId: payloadParent,
                agentType: label,
                agentNickname: nil
            ))
        }
        guard let subagent = source["subagent"] as? [String: Any],
              !subagent.isEmpty else {
            return .root
        }
        // Spawned workers nest the parent under `source.subagent.thread_spawn`;
        // auto-review (guardian) threads record it on the payload itself.
        let parent = firstStringRecursively(in: subagent, key: "parent_thread_id")
            ?? payloadParent
        guard let parent, !parent.isEmpty else { return .unavailable }

        let agentType = firstStringRecursively(in: subagent, key: "agent_role")
            ?? subagent["other"] as? String
            ?? subagent.keys.sorted().first
        let nickname = firstStringRecursively(in: subagent, key: "agent_nickname")
        return .subagent(CodexSubagentMetadata(
            parentThreadId: parent,
            agentType: agentType,
            agentNickname: nickname
        ))
    }

    nonisolated static func codexSubagentMetadata(inTranscriptPath path: String) -> CodexSubagentMetadata? {
        guard case .subagent(let metadata) = inspectCodexSubagentMetadata(
            inTranscriptPath: path
        ) else {
            return nil
        }
        return metadata
    }

    nonisolated static func codexSubagentMetadata(
        threadId: String,
        transcriptPath: String?,
        statePath overrideStatePath: String? = nil
    ) -> CodexSubagentMetadata? {
        if let transcriptPath {
            switch inspectCodexSubagentMetadata(inTranscriptPath: transcriptPath) {
            case .subagent(let metadata):
                return metadata
            case .root:
                return nil
            case .unavailable:
                break
            }
        }

        return codexSpawnEdgeRecords(
            threadIds: [threadId],
            statePath: overrideStatePath
        )[threadId]?.metadata
    }

    /// Resolve spawn relations/statuses in one read-only connection. Queries are
    /// chunked to keep SQLite variable counts bounded when restoring many cards.
    private nonisolated static func codexSpawnEdgeRecords(
        threadIds: Set<String>,
        statePath overrideStatePath: String? = nil
    ) -> [String: CodexSpawnEdgeRecord] {
        guard !threadIds.isEmpty else { return [:] }
        guard let statePath = overrideStatePath else {
            // A thread can live in any Codex root; the first root that knows it wins.
            var merged: [String: CodexSpawnEdgeRecord] = [:]
            for root in codexStateRoots() {
                let unresolved = threadIds.subtracting(merged.keys)
                guard !unresolved.isEmpty else { break }
                let found = codexSpawnEdgeRecords(threadIds: unresolved, statePath: "\(root)/state_5.sqlite")
                merged.merge(found) { current, _ in current }
            }
            return merged
        }
        return withSQLiteDatabase(at: statePath) { db in
            let edgeColumns = sqliteTableColumns(db: db, tableName: "thread_spawn_edges")
            guard Set(["parent_thread_id", "child_thread_id", "status"]).isSubset(of: edgeColumns) else {
                return [:]
            }
            let threadColumns = sqliteTableColumns(db: db, tableName: "threads")
            let canJoinThreads = threadColumns.contains("id")
            let roleExpression = canJoinThreads && threadColumns.contains("agent_role")
                ? "thread.agent_role" : "NULL"
            let nicknameExpression = canJoinThreads && threadColumns.contains("agent_nickname")
                ? "thread.agent_nickname" : "NULL"
            let sourceExpression = canJoinThreads && threadColumns.contains("source")
                ? "thread.source" : "NULL"
            let transcriptExpression = canJoinThreads && threadColumns.contains("rollout_path")
                ? "thread.rollout_path" : "NULL"
            let join = canJoinThreads
                ? "LEFT JOIN threads AS thread ON thread.id = edge.child_thread_id"
                : ""

            let orderedIds = threadIds.sorted()
            let chunkSize = 200
            var records: [String: CodexSpawnEdgeRecord] = [:]
            for start in stride(from: 0, to: orderedIds.count, by: chunkSize) {
                let end = min(start + chunkSize, orderedIds.count)
                let chunk = Array(orderedIds[start..<end])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let sql = """
                    SELECT edge.child_thread_id, edge.parent_thread_id, edge.status,
                           \(roleExpression), \(nicknameExpression), \(sourceExpression),
                           \(transcriptExpression)
                    FROM thread_spawn_edges AS edge
                    \(join)
                    WHERE edge.child_thread_id IN (\(placeholders))
                    """
                guard let statement = prepareSQLiteStatement(db: db, sql: sql) else { continue }
                for (offset, threadId) in chunk.enumerated() {
                    bindSQLiteText(threadId, to: statement, index: Int32(offset + 1))
                }
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let child = nonEmptySQLiteColumnString(statement, index: 0),
                          let parent = nonEmptySQLiteColumnString(statement, index: 1) else {
                        continue
                    }
                    var agentType = nonEmptySQLiteColumnString(statement, index: 3)
                    var nickname = nonEmptySQLiteColumnString(statement, index: 4)
                    if let source = nonEmptySQLiteColumnString(statement, index: 5),
                       let data = source.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) {
                        agentType = agentType ?? firstStringRecursively(in: json, key: "agent_role")
                        nickname = nickname ?? firstStringRecursively(in: json, key: "agent_nickname")
                    }
                    records[child] = CodexSpawnEdgeRecord(
                        metadata: CodexSubagentMetadata(
                            parentThreadId: parent,
                            agentType: agentType,
                            agentNickname: nickname
                        ),
                        status: nonEmptySQLiteColumnString(statement, index: 2),
                        transcriptPath: nonEmptySQLiteColumnString(statement, index: 6)
                    )
                }
                sqlite3_finalize(statement)
            }
            return records
        } ?? [:]
    }

    private nonisolated static func readFirstLine(path: String, maxBytes: Int = 2_000_000) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        var data = Data()
        while data.count < maxBytes {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                data.append(chunk[..<newline])
                break
            }
            data.append(chunk)
        }
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func firstStringRecursively(in value: Any, key: String) -> String? {
        if let dict = value as? [String: Any] {
            if let string = dict[key] as? String,
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return string
            }
            for child in dict.values {
                if let found = firstStringRecursively(in: child, key: key) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = firstStringRecursively(in: child, key: key) {
                    return found
                }
            }
        }
        return nil
    }

    private nonisolated static func nonEmptySQLiteColumnString(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let value = sqliteColumnString(statement, index: index)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Find the most recent Codex session file matching a CWD
    /// Scans back up to 7 days to cover long-running sessions that span day boundaries
    private nonisolated static func findRecentCodexSession(base: String, cwd: String, after: Date?, fm: FileManager) -> String? {
        findRecentCodexSessions(base: base, after: after, fm: fm)
            .first(where: { codexSessionMatchesCwd(path: $0, cwd: cwd) })
    }

    private nonisolated static func findRecentCodexSessions(base: String, after: Date?, fm: FileManager) -> [String] {
        let cal = Calendar.current
        let now = Date()
        var dirs: [String] = []
        for daysBack in 0..<7 {
            guard let date = cal.date(byAdding: .day, value: -daysBack, to: now) else { continue }
            let y = String(format: "%04d", cal.component(.year, from: date))
            let m = String(format: "%02d", cal.component(.month, from: date))
            let d = String(format: "%02d", cal.component(.day, from: date))
            let dir = "\(base)/\(y)/\(m)/\(d)"
            if fm.fileExists(atPath: dir) {
                dirs.append(dir)
            }
        }
        guard !dirs.isEmpty else { return [] }
        return scanCodexDir(dirs: dirs, after: after, fm: fm)
    }

    private nonisolated static func scanCodexDir(dirs: [String], after: Date?, fm: FileManager) -> [String] {
        var results: [String] = []
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            // Sort descending to check newest first
            let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }.sorted(by: >)

            for file in jsonlFiles.prefix(20) {
                let fullPath = "\(dir)/\(file)"
                if let start = after,
                   let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let modified = attrs[.modificationDate] as? Date,
                   modified < start.addingTimeInterval(-10) {
                    continue
                }
                results.append(fullPath)
            }
        }
        return results
    }

    /// Check if a Codex session file's CWD matches the target
    private nonisolated static func codexSessionMatchesCwd(path: String, cwd: String) -> Bool {
        codexSessionCwd(path: path) == cwd
    }

    nonisolated static func codexSessionCwd(path: String) -> String? {
        guard let firstLine = readFirstLine(path: path),
              let lineData = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let payload = json["payload"] as? [String: Any],
              let sessionCwd = payload["cwd"] as? String else { return nil }
        return sessionCwd
    }

    /// Extract session ID from Codex filename: rollout-2026-04-04T20-54-48-{uuid}.jsonl
    private nonisolated static func extractCodexSessionId(from filename: String) -> String {
        // Format: rollout-YYYY-MM-DDThh-mm-ss-{uuid}.jsonl
        let name = filename.replacingOccurrences(of: ".jsonl", with: "")
        // The UUID is the last 36 chars (8-4-4-4-12)
        // Pattern: after the datetime portion, everything from the 4th dash group onwards is the UUID
        let parts = name.split(separator: "-")
        // rollout-YYYY-MM-DDThh-mm-ss-{8}-{4}-{4}-{4}-{12}
        // That's: [rollout, YYYY, MM, DDThh, mm, ss, uuid1, uuid2, uuid3, uuid4, uuid5]
        if parts.count >= 11 {
            return parts.suffix(5).joined(separator: "-")
        }
        return name
    }

    private nonisolated static func extractTextContent(from rawContent: Any?) -> String? {
        if let text = rawContent as? String, !text.isEmpty {
            return text
        }
        if let items = rawContent as? [[String: Any]] {
            for item in items {
                if let text = item["text"] as? String, !text.isEmpty {
                    return text
                }
                if let output = item["output"] as? [String: Any],
                   let text = output["text"] as? String, !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private nonisolated static func readTranscriptTail(path: String, maxBytes: UInt64 = 65536) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, maxBytes)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func parseISO8601Timestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    nonisolated static func codexLatestTerminalTurnTimestamp(in transcriptTail: String) -> Date? {
        let terminalEventTypes: Set<String> = ["task_complete", "turn_aborted", "turn_failed"]
        var latest: Date?

        for line in transcriptTail.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["type"] as? String) == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String,
                  terminalEventTypes.contains(eventType),
                  let timestamp = json["timestamp"] as? String,
                  let date = parseISO8601Timestamp(timestamp) else { continue }

            if latest == nil || date > latest! {
                latest = date
            }
        }

        return latest
    }

    /// Read model and recent messages from a Codex transcript file
    nonisolated static func readRecentFromCodexTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let text = readTranscriptTail(path: path) else { return (nil, []) }

        var model: String?
        var turnModel: String?
        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            let type = json["type"] as? String ?? ""

            // Extract model from session_meta
            if type == "session_meta", model == nil,
               let payload = json["payload"] as? [String: Any] {
                model = payload["model"] as? String
                    ?? payload["model_provider"] as? String
            }
            // turn_context names the model each turn actually ran on; current
            // session_meta only has the provider ("openai"), which is no label.
            if type == "turn_context",
               let payload = json["payload"] as? [String: Any],
               let observation = ModelObservation.from(model: payload["model"], effort: nil) {
                turnModel = observation.model
            }

            // Prefer event_msg (cleaner user messages from Codex).
            if type == "event_msg",
               let payload = json["payload"] as? [String: Any],
               let msgType = payload["type"] as? String,
               let msg = payload["message"] as? String, !msg.isEmpty {
                if msgType == "user_message" {
                    userMessages.append((index, msg))
                }
            }

            if let assistantText = JSONLTailer.codexPublicAssistantText(from: json),
               assistantMessages.last?.1 != assistantText {
                assistantMessages.append((index, assistantText))
            }

            // response_item user entries often include injected system/tool
            // context, so only use them when no cleaner event_msg was found.
            if type == "response_item", userMessages.isEmpty,
               let payload = json["payload"] as? [String: Any],
               payload["type"] as? String == "message",
               payload["role"] as? String == "user",
               let content = payload["content"] as? [[String: Any]],
               let text = content.first(where: { $0["type"] as? String == "input_text" })?["text"] as? String,
               !text.isEmpty {
                userMessages.append((index, text))
            }
            index += 1
        }

        var combined: [(Int, ChatMessage)] = []
        for (i, text) in userMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: true, text: text)))
        }
        for (i, text) in assistantMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: false, text: text)))
        }
        combined.sort { $0.0 < $1.0 }
        let recent = Array(combined.suffix(3).map { $0.1 })

        return (turnModel ?? model, recent)
    }

    /// Read model and last 3 user/assistant messages from a transcript file's tail
    /// First text block of a transcript row worth showing, cleaned the way the
    /// live tail cleans it (`JSONLTailer.extractText`): mcode's reasoning blobs
    /// are skipped and leading injected wrappers removed, so a card rebuilt on
    /// attach reads the same as one fed by the tailer.
    nonisolated static func firstDisplayText(in blocks: [[String: Any]]) -> String? {
        for block in blocks {
            guard block["type"] as? String == "text",
                  let raw = block["text"] as? String,
                  !JSONLTailer.isThinkingBlob(raw) else { continue }
            let text = JSONLTailer.stripDisplayWrappers(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    nonisolated static func readRecentFromTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, []) }
        defer { handle.closeFile() }

        // Read last 64KB
        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 65536)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, []) }

        var model: String?
        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            let type = json["type"] as? String
            let message = (json["message"] as? [String: Any]) ?? json
            let role = (message["role"] as? String) ?? type

            guard let role else { continue }
            let normalizedRole = role.lowercased()

            if model == nil, let m = message["model"] as? String, !m.isEmpty {
                model = m
            }

            // Extract text content
            var textContent: String?
            if normalizedRole == "user" || normalizedRole == "user_input" {
                if let content = message["content"] as? String {
                    textContent = JSONLTailer.stripDisplayWrappers(content)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let contentArray = message["content"] as? [[String: Any]] {
                    textContent = firstDisplayText(in: contentArray)
                }
            } else if normalizedRole == "assistant" || normalizedRole == "planner_response" {
                if let content = message["content"] as? String {
                    textContent = JSONLTailer.isThinkingBlob(content)
                        ? nil
                        : content.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let contentArray = message["content"] as? [[String: Any]] {
                    textContent = firstDisplayText(in: contentArray)
                } else if let thinking = message["thinking"] as? String {
                    textContent = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            if let text = textContent, !text.isEmpty {
                if normalizedRole == "user" || normalizedRole == "user_input" {
                    // Same rules as the live tail: injected (isMeta) rows and
                    // local slash commands (/model) are not prompts; a prompt
                    // command reads as typed ("/review foo").
                    if json["isMeta"] as? Bool != true {
                        switch JSONLTailer.claudeCommandEcho(text) {
                        case .local?: break
                        case .prompt(let command)?: userMessages.append((index, command))
                        case nil: userMessages.append((index, text))
                        }
                    }
                } else if normalizedRole == "assistant" || normalizedRole == "planner_response" {
                    assistantMessages.append((index, text))
                }
            }
            index += 1
        }

        // Build recent messages: take last few user+assistant, sorted by order, keep 3
        var combined: [(Int, ChatMessage)] = []
        for (i, text) in userMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: true, text: text)))
        }
        for (i, text) in assistantMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: false, text: text)))
        }
        combined.sort { $0.0 < $1.0 }
        let recent = Array(combined.suffix(3).map { $0.1 })

        return (model, recent)
    }
}

/// Encode a path the same way Claude Code does for project directory names:
/// "/" → "-", non-ASCII → "-", spaces → "-"
extension String {
    func claudeProjectDirEncoded() -> String {
        var result = ""
        for c in self.unicodeScalars {
            if c == "/" || c == " " || c.value > 127 {
                result.append("-")
            } else {
                result.append(Character(c))
            }
        }
        return result
    }

    func appProjectDirEncoded() -> String {
        let encoded = claudeProjectDirEncoded()
        if encoded.hasPrefix("-") {
            return String(encoded.dropFirst())
        }
        return encoded
    }
}
