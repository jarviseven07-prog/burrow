import Foundation
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "PermissionDeny")

/// Cached metadata for an in-flight tool_use_id, written on PreToolUse and consumed by
/// downstream PermissionRequest / PostToolUse events.
///
/// This lets us (1) correlate PermissionRequest payloads back to the originating tool
/// invocation even when some providers strip fields on re-emit, (2) drain stale queue
/// entries when the agent moved on (PostToolUse arrives while a PermissionRequest for
/// the same id is still queued), and (3) dedupe duplicate PermissionRequest replays.
struct PreToolUseRecord {
    let sessionId: String
    let toolName: String?
    let toolDescription: String?
    let toolInput: [String: Any]?
    let receivedAt: Date
    /// Which agent made the call (nil: the main thread) and the tool's own
    /// name, so a PermissionRequest without an id can find its call.
    var agentId: String? = nil
    var rawToolName: String? = nil
}

extension AppState {
    /// TTL for cached PreToolUse records. Generous — tool calls may block on user input
    /// or long-running subprocesses; pruning reclaims memory for aborted/abandoned ids.
    static let pendingToolUseTTL: TimeInterval = 900  // 15 minutes

    /// Cache a PreToolUse so later PermissionRequest / PostToolUse events carrying the
    /// same tool_use_id can be correlated back to the originating invocation.
    func cachePreToolUseIfApplicable(_ event: HookEvent) {
        guard EventNormalizer.normalize(event.eventName) == "PreToolUse" else { return }
        guard let toolUseId = event.toolUseId, !toolUseId.isEmpty else { return }

        pendingToolUses[toolUseId] = PreToolUseRecord(
            sessionId: event.sessionId ?? "default",
            toolName: event.activityLabel,
            toolDescription: event.toolDescription,
            toolInput: event.toolInput,
            receivedAt: Date(),
            agentId: event.agentId,
            rawToolName: event.toolName
        )
    }

    /// Two tool inputs of the same call. `description` is left out: Codex adds
    /// the approval reason there on PermissionRequest only.
    static func sameToolInput(_ lhs: [String: Any]?, _ rhs: [String: Any]?) -> Bool {
        var lhs = lhs ?? [:]
        var rhs = rhs ?? [:]
        lhs.removeValue(forKey: "description")
        rhs.removeValue(forKey: "description")
        return NSDictionary(dictionary: lhs).isEqual(to: rhs)
    }

    /// The tool_use_id of the call a PermissionRequest is about.
    ///
    /// Claude Code's PermissionRequest carries none (hooks docs: "like
    /// PreToolUse hooks, but without tool_use_id"), nor does Codex's. The call's
    /// own PreToolUse — same conversation, agent, tool and input — came just
    /// before it, so its id is taken from there. Only a single match counts:
    /// two identical calls in flight cannot be told apart, and a wrong guess
    /// would let one call's progress answer the other.
    func correlatedToolUseId(for event: HookEvent) -> String? {
        if let id = event.toolUseId, !id.isEmpty { return id }
        let sessionId = event.sessionId ?? "default"
        let claimed = Set(permissionQueue.compactMap(\.toolUseId))
        let matches = pendingToolUses.filter { id, record in
            !claimed.contains(id) && Self.record(record, isCallOf: event, sessionId: sessionId)
        }
        return matches.count == 1 ? matches.first?.key : nil
    }

    private static func record(_ record: PreToolUseRecord, isCallOf event: HookEvent, sessionId: String) -> Bool {
        record.sessionId == sessionId
            && record.agentId == event.agentId
            && record.rawToolName == event.toolName
            && sameToolInput(record.toolInput, event.toolInput)
    }

    /// A call you deny never runs and never posts; forget its PreToolUse so
    /// it cannot make Claude's retry of the same command look ambiguous.
    func forgetToolUse(of request: PermissionRequest) {
        guard let id = request.toolUseId, !id.isEmpty else { return }
        pendingToolUses.removeValue(forKey: id)
    }

    /// Drop cache entries for a completed tool invocation. If a PermissionRequest for the
    /// same id is still sitting in the queue (e.g. agent moved on after a local timeout),
    /// drain it with a deny so we don't hold the UI hostage to a dead waiter.
    func resolveToolUseIfCompleted(_ event: HookEvent) {
        let normalized = EventNormalizer.normalize(event.eventName)
        guard normalized == "PostToolUse"
                || normalized == "PostToolUseFailure"
                || normalized == "PermissionDenied"
        else { return }
        guard let toolUseId = event.toolUseId, !toolUseId.isEmpty else { return }

        pendingToolUses.removeValue(forKey: toolUseId)

        guard let staleIndex = permissionQueue.firstIndex(where: { $0.toolUseId == toolUseId })
        else { return }

        let stale = permissionQueue.remove(at: staleIndex)
        log.notice("⚠️ permission deny reason=resolveToolUseIfCompleted session=\(stale.event.sessionId ?? "nil", privacy: .public) toolUseId=\(toolUseId, privacy: .public) tool=\(stale.event.toolName ?? "nil", privacy: .public) triggerEvent=\(normalized, privacy: .public)")
        let denyBody = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#
        stale.continuation.resume(returning: Data(denyBody.utf8))

        // If the card we were showing was the drained one, advance to the next pending
        // request (or collapse if nothing is left).
        let wasHead = staleIndex == 0
        if wasHead {
            if permissionQueue.isEmpty {
                if case .approvalCard = surface {
                    surface = .collapsed
                }
            } else {
                showNextPending()
            }
        }
    }

    /// Let go of permission requests the agent has moved past, for the ones
    /// whose call has no known tool_use_id (no PreToolUse matched it).
    ///
    /// Requests with an id are left to `resolveToolUseIfCompleted`: only their
    /// own call's events answer them. Without one, approving in the terminal
    /// would leave the card up forever (#216), so two signals still count:
    /// - the request's own tool finished — a PostToolUse with the same tool and
    ///   input, while no other call that looks the same is in flight;
    /// - the turn ended (Stop) or a new one began (UserPromptSubmit).
    /// Another tool starting or finishing does not: Claude runs several tools of
    /// one message at once, and their hooks arrive while a request waits
    /// (health check 2026-11-04 #1). Only the agent that asked can move past
    /// its own prompt — a background agent's hooks never count (design/v20).
    ///
    /// Burrow answers these with no decision: the user said nothing here, and
    /// an agent that somehow still waits falls back to its own prompt.
    func resolveOrphanPermissionsOnActivity(_ event: HookEvent) {
        let normalized = EventNormalizer.normalize(event.eventName)
        let sessionId = event.sessionId ?? "default"
        func isOrphan(_ item: PermissionRequest) -> Bool {
            (item.event.sessionId ?? "default") == sessionId
                && item.event.agentId == event.agentId
                && (item.toolUseId?.isEmpty ?? true)
        }

        let movedPast: Set<UUID>
        switch normalized {
        case "Stop", "UserPromptSubmit":
            movedPast = Set(permissionQueue.filter(isOrphan).map(\.id))
        case "PostToolUse", "PostToolUseFailure":
            // Its own id was already dropped by resolveToolUseIfCompleted, so
            // any record left that looks the same is another call in flight.
            // Each of those may still own one waiting card; a card beyond them
            // belongs to the call that just finished. Identical cards look the
            // same to the user, so the oldest goes.
            let lookalikesInFlight = pendingToolUses.values.filter {
                Self.record($0, isCallOf: event, sessionId: sessionId)
            }.count
            let waiting = permissionQueue.filter {
                isOrphan($0)
                    && $0.event.toolName == event.toolName
                    && Self.sameToolInput($0.event.toolInput, event.toolInput)
            }
            guard waiting.count > lookalikesInFlight, let own = waiting.first else { return }
            movedPast = [own.id]
        default:
            return
        }
        guard !movedPast.isEmpty else { return }

        let headWasResolved = permissionQueue.first.map { movedPast.contains($0.id) } ?? false
        permissionQueue.removeAll { item in
            guard movedPast.contains(item.id) else { return false }
            log.notice("permission let go reason=resolveOrphanPermissionsOnActivity session=\(sessionId, privacy: .public) tool=\(item.event.toolName ?? "nil", privacy: .public) triggerEvent=\(normalized, privacy: .public)")
            item.continuation.resume(returning: Self.noDecisionResponse)
            return true
        }

        // If the card we were showing was one of them, advance to the next
        // pending request (or collapse if nothing is left).
        if headWasResolved {
            if permissionQueue.isEmpty {
                if case .approvalCard = surface {
                    surface = .collapsed
                }
            } else {
                showNextPending()
            }
        }
    }

    /// The request an agent says was answered somewhere else. OpenCode's plugin
    /// forwards `permission.replied` / `question.replied` / `form.replied` as a
    /// PostToolUse that names its `_opencode_request_id` (health check
    /// 2026-11-04 #2): two requests can wait in one OpenCode conversation, and
    /// answering one in the TUI must not settle the other.
    static func requestAnsweredElsewhere(by event: HookEvent) -> String? {
        let normalized = EventNormalizer.normalize(event.eventName)
        guard normalized == "PostToolUse" || normalized == "PostToolUseFailure",
              let id = event.rawJSON["_opencode_request_id"] as? String, !id.isEmpty
        else { return nil }
        return id
    }

    /// Let go of the one request, approval or question, that the agent says was
    /// answered elsewhere. No decision goes back: the plugin then replies nothing.
    func resolveRequestAnsweredElsewhere(_ requestId: String, sessionId: String) {
        func isNamed(_ event: HookEvent) -> Bool {
            (event.sessionId ?? "default") == sessionId
                && (event.rawJSON["_opencode_request_id"] as? String) == requestId
        }
        var settled = false
        permissionQueue.removeAll { item in
            guard isNamed(item.event) else { return false }
            log.notice("permission let go reason=answeredElsewhere session=\(sessionId, privacy: .public) request=\(requestId, privacy: .public)")
            item.continuation.resume(returning: Self.noDecisionResponse)
            settled = true
            return true
        }
        questionQueue.removeAll { item in
            guard !item.isCodexAppServer, isNamed(item.event) else { return false }
            item.resolution.resumeHook(returning: Self.noDecisionResponse)
            settled = true
            return true
        }
        if settled { showNextPending() }
    }

    /// A hook answer with no decision: the agent goes on as if Burrow had not
    /// been asked.
    static let noDecisionResponse = Data("{}".utf8)

    /// Remove stale cache entries. Called from the cleanup timer tick.
    func prunePendingToolUses(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-AppState.pendingToolUseTTL)
        pendingToolUses = pendingToolUses.filter { $0.value.receivedAt >= cutoff }
    }

    /// Try to merge this permission request into an existing queue entry for the same
    /// tool_use_id. Returns true when the new arrival was treated as a replay and its
    /// continuation has already been resolved (caller must not enqueue).
    ///
    /// Behavior: the newer continuation replaces the queued one in-place. The older
    /// continuation is denied so Claude's prior waiter doesn't hang; the queue slot and
    /// its position remain the same so the visible card doesn't reshuffle under the user.
    func mergeDuplicatePermissionRequest(_ request: PermissionRequest) -> Bool {
        guard let toolUseId = request.toolUseId, !toolUseId.isEmpty else { return false }
        guard let existingIndex = permissionQueue.firstIndex(where: { $0.toolUseId == toolUseId })
        else { return false }

        let existing = permissionQueue[existingIndex]
        // #169: a shared tool_use_id alone is not enough to call this a replay.
        // Claude Code can emit several *parallel* tool calls (e.g. reading 4
        // files at once); if they carry the same id but different inputs they are
        // distinct requests and each needs its own decision. Treat it as a replay
        // — deny the old waiter, keep the new one in place — only when the tool
        // inputs match. Otherwise let the new request enqueue on its own.
        let existingInput = existing.event.toolInput ?? [:]
        let newInput = request.event.toolInput ?? [:]
        guard NSDictionary(dictionary: existingInput).isEqual(to: NSDictionary(dictionary: newInput)) else {
            return false
        }
        log.notice("⚠️ permission deny reason=mergeDuplicatePermissionRequest session=\(existing.event.sessionId ?? "nil", privacy: .public) toolUseId=\(toolUseId, privacy: .public) tool=\(existing.event.toolName ?? "nil", privacy: .public)")
        let denyBody = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#
        existing.continuation.resume(returning: Data(denyBody.utf8))
        // Same request, new waiter: it keeps its identity, so its reminders
        // and the card showing it carry on rather than starting over.
        permissionQueue[existingIndex] = PermissionRequest(
            id: existing.id, event: request.event, continuation: request.continuation,
            toolUseId: request.toolUseId, connectionId: request.connectionId
        )
        return true
    }

    /// Backfill tool metadata from the cached PreToolUse when the PermissionRequest
    /// payload is missing fields (observed with some third-party CLIs that re-emit
    /// permission events without replaying the tool input).
    func enrichPermissionRequestFromCache(sessionId: String, event: HookEvent) {
        guard let toolUseId = event.toolUseId, !toolUseId.isEmpty else { return }
        guard let record = pendingToolUses[toolUseId] else { return }

        if sessions[sessionId]?.currentTool == nil, let name = record.toolName {
            sessions[sessionId]?.currentTool = name
        }
        if sessions[sessionId]?.toolDescription == nil, let desc = record.toolDescription {
            sessions[sessionId]?.toolDescription = desc
        }
    }
}
