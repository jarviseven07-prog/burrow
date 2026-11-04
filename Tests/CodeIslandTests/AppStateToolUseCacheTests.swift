import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class AppStateToolUseCacheTests: XCTestCase {

    // MARK: - Cache lifecycle

    func testPreToolUseCachesRecord() throws {
        let appState = AppState()
        let event = try makeHookEvent(
            name: "PreToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_1",
            toolInput: ["command": "ls"]
        )

        appState.handleEvent(event)

        let cached = try XCTUnwrap(appState.pendingToolUses["toolu_1"])
        XCTAssertEqual(cached.sessionId, "s1")
        XCTAssertEqual(cached.toolName, "Bash")
    }

    func testPostToolUseClearsCache() throws {
        let appState = AppState()
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))
        XCTAssertNotNil(appState.pendingToolUses["toolu_1"])

        appState.handleEvent(try makeHookEvent(name: "PostToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))

        XCTAssertNil(appState.pendingToolUses["toolu_1"])
    }

    func testPostToolUseFailureAlsoClearsCache() throws {
        let appState = AppState()
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))

        appState.handleEvent(try makeHookEvent(name: "PostToolUseFailure", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))

        XCTAssertNil(appState.pendingToolUses["toolu_1"])
    }

    func testPruneRemovesExpiredRecords() throws {
        let appState = AppState()
        appState.pendingToolUses["ancient"] = PreToolUseRecord(
            sessionId: "s1",
            toolName: "Bash",
            toolDescription: nil,
            toolInput: nil,
            receivedAt: Date(timeIntervalSinceNow: -(AppState.pendingToolUseTTL + 60))
        )
        appState.pendingToolUses["fresh"] = PreToolUseRecord(
            sessionId: "s1",
            toolName: "Bash",
            toolDescription: nil,
            toolInput: nil,
            receivedAt: Date()
        )

        appState.prunePendingToolUses()

        XCTAssertNil(appState.pendingToolUses["ancient"])
        XCTAssertNotNil(appState.pendingToolUses["fresh"])
    }

    // MARK: - Duplicate PermissionRequest replay

    func testDuplicatePermissionRequestReplacesContinuationAndDeniesOld() async throws {
        let appState = AppState()
        let first = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "dup_1")
        let second = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "dup_1")

        let firstTask = await startHookRequest { appState.handlePermissionRequest(first, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)

        let secondTask = await startHookRequest { appState.handlePermissionRequest(second, continuation: $0) }

        // The old continuation should be denied immediately; queue length stays 1.
        let firstResponse = try await awaitValue(of: firstTask)
        XCTAssertEqual(try behavior(firstResponse), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 1)

        // Second (replacement) continuation still waits for user decision.
        appState.approvePermission()
        let secondResponse = try await awaitValue(of: secondTask)
        XCTAssertEqual(try behavior(secondResponse), "allow")
    }

    /// Repro for #169: parallel tool calls that share a tool_use_id but operate
    /// on different inputs (e.g. "Read 4 files" at once) must not deny one
    /// another. Merging by id alone denied all but the last, which users saw as
    /// "denied by PermissionRequest hook" on tools they never rejected.
    func testParallelRequestsSharingIdButDifferentInputAreNotMerged() async throws {
        let appState = AppState()
        let readA = try makeHookEvent(
            name: "PermissionRequest", sessionId: "s1", toolName: "Read",
            toolUseId: "shared_id", toolInput: ["file_path": "/a.txt"]
        )
        let readB = try makeHookEvent(
            name: "PermissionRequest", sessionId: "s1", toolName: "Read",
            toolUseId: "shared_id", toolInput: ["file_path": "/b.txt"]
        )

        let taskA = await startHookRequest { appState.handlePermissionRequest(readA, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)

        let taskB = await startHookRequest { appState.handlePermissionRequest(readB, continuation: $0) }

        XCTAssertEqual(appState.permissionQueue.count, 2,
            "Parallel requests with different inputs must not deny each other (#169)")
        await assertStillPending(taskA)

        // Both stay until the user decides each one.
        appState.approvePermission()
        let responseA = try await awaitValue(of: taskA)
        XCTAssertEqual(try behavior(responseA), "allow")
        appState.approvePermission()
        let responseB = try await awaitValue(of: taskB)
        XCTAssertEqual(try behavior(responseB), "allow")
    }

    // MARK: - Stale queue drain via PostToolUse

    func testPostToolUseDrainsQueuedPermissionForSameId() async throws {
        let appState = AppState()
        let pending = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "toolu_drain")

        let responseTask = await startHookRequest { appState.handlePermissionRequest(pending, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)

        // Agent moved on — emits PostToolUse for the same tool_use_id.
        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_drain"
        ))

        let response = try await awaitValue(of: responseTask)
        XCTAssertEqual(try behavior(response), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    func testPostToolUseDoesNotAffectUnrelatedQueueEntries() async throws {
        let appState = AppState()
        let kept = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "keep_me")
        let drained = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "drop_me")

        let keptTask = await startHookRequest { appState.handlePermissionRequest(kept, continuation: $0) }
        let drainedTask = await startHookRequest { appState.handlePermissionRequest(drained, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 2)

        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "drop_me"
        ))

        let drainedResponse = try await awaitValue(of: drainedTask)
        XCTAssertEqual(try behavior(drainedResponse), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.permissionQueue.first?.toolUseId, "keep_me")

        appState.approvePermission()
        let keptResponse = try await awaitValue(of: keptTask)
        XCTAssertEqual(try behavior(keptResponse), "allow")
    }

    // MARK: - issue #216: a request answered in the terminal leaves the queue

    /// Repro for #216, with the payloads Claude Code really sends: its
    /// PermissionRequest carries no tool_use_id (hooks docs: "like PreToolUse
    /// hooks, but without tool_use_id"), so the request is matched back to its
    /// own PreToolUse. Approving in the terminal, the tool runs and its own
    /// PostToolUse takes the card down.
    func testRequestAnsweredInTheTerminalLeavesWithItsOwnPostToolUse() async throws {
        let appState = AppState()
        let input: [String: Any] = ["command": "rm -rf build", "description": "Clean the build"]
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_rm", toolInput: input))
        let request = try makeHookEvent(name: "PermissionRequest", sessionId: "s1", toolName: "Bash", toolUseId: nil, toolInput: input)

        let responseTask = await startHookRequest { appState.handlePermissionRequest(request, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.first?.toolUseId, "toolu_rm", "found through its own PreToolUse")

        appState.handleEvent(try makeHookEvent(name: "PostToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_rm", toolInput: input))

        _ = try await awaitValue(of: responseTask)
        XCTAssertTrue(appState.permissionQueue.isEmpty)
    }

    /// No PreToolUse to match (an agent that sends none, or none with an id):
    /// only the request's own tool finishing — same name, same input — or the
    /// turn ending counts as answered elsewhere, and Burrow then lets go with
    /// no decision instead of saying yes for the user.
    func testUnmatchedRequestLeavesOnlyWithItsOwnToolOrTheTurnsEnd() async throws {
        let appState = AppState()
        let orphan = try makeHookEvent(
            name: "PermissionRequest", sessionId: "s1", toolName: "Bash", toolUseId: nil,
            toolInput: ["command": "echo hi"]
        )
        let responseTask = await startHookRequest { appState.handlePermissionRequest(orphan, continuation: $0) }
        XCTAssertNil(appState.permissionQueue.first?.toolUseId)

        // Another tool starting or finishing is not this request moving on.
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Grep", toolUseId: nil, toolInput: ["pattern": "x"]))
        appState.handleEvent(try makeHookEvent(name: "PostToolUse", sessionId: "s1", toolName: "Grep", toolUseId: nil, toolInput: ["pattern": "x"]))
        appState.handleEvent(try makeHookEvent(name: "PostToolUse", sessionId: "s1", toolName: "Bash", toolUseId: nil, toolInput: ["command": "ls"]))
        XCTAssertEqual(appState.permissionQueue.count, 1)
        await assertStillPending(responseTask)

        appState.handleEvent(try makeHookEvent(name: "PostToolUse", sessionId: "s1", toolName: "Bash", toolUseId: nil, toolInput: ["command": "echo hi"]))
        let response = try await awaitValue(of: responseTask)
        XCTAssertNil(try decisionBehavior(response), "let go without answering for the user")
        XCTAssertTrue(appState.permissionQueue.isEmpty)

        let second = await startHookRequest { appState.handlePermissionRequest(orphan, continuation: $0) }
        appState.handleEvent(try makeHookEvent(name: "Stop", sessionId: "s1", toolName: nil, toolUseId: nil))
        let secondResponse = try await awaitValue(of: second)
        XCTAssertNil(try decisionBehavior(secondResponse), "the turn is over")
        XCTAssertTrue(appState.permissionQueue.isEmpty)
    }

    /// A background agent working in the same session is not the user saying yes
    /// to the main thread's request (Burrow design/v20 review).
    func testAnotherAgentsActivityDoesNotApproveAnOrphan() async throws {
        let appState = AppState()
        let orphan = try makeHookEvent(
            name: "PermissionRequest",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: nil,
            toolInput: ["command": "rm -rf build"]
        )
        let responseTask = await startHookRequest { appState.handlePermissionRequest(orphan, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.handleEvent(try makeRawHookEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "s1",
            "agent_id": "bg-agent",
            "tool_name": "Bash",
            "tool_input": ["command": "rm -rf build"],
        ]))
        XCTAssertEqual(appState.permissionQueue.count, 1, "still waiting for the user")

        appState.handleEvent(try makeHookEvent(name: "PostToolUse", sessionId: "s1", toolName: "Bash", toolUseId: nil, toolInput: ["command": "rm -rf build"]))
        let response = try await awaitValue(of: responseTask)
        XCTAssertNil(try decisionBehavior(response), "the main thread itself moved on")
    }

    // MARK: - Health check 2026-11-04 #1: parallel tool calls

    /// Claude calls a Read that needs approval and a Grep that does not in one
    /// message. The Grep's hooks arriving while the Read waits used to approve
    /// the Read for the user.
    func testSiblingToolOfTheSameMessageDoesNotAnswerARequest() async throws {
        let appState = AppState()
        let readInput: [String: Any] = ["file_path": "/Users/me/.ssh/config"]
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Read", toolUseId: "toolu_read", toolInput: readInput))
        let request = try makeHookEvent(name: "PermissionRequest", sessionId: "s1", toolName: "Read", toolUseId: nil, toolInput: readInput)
        let responseTask = await startHookRequest { appState.handlePermissionRequest(request, continuation: $0) }

        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Grep", toolUseId: "toolu_grep", toolInput: ["pattern": "Host"]))
        appState.handleEvent(try makeHookEvent(name: "PostToolUse", sessionId: "s1", toolName: "Grep", toolUseId: "toolu_grep", toolInput: ["pattern": "Host"]))

        XCTAssertEqual(appState.permissionQueue.count, 1, "the Grep finishing is not an answer to the Read")
        await assertStillPending(responseTask)

        appState.denyPermission()
        let responseTaskResponse = try await awaitValue(of: responseTask)
        XCTAssertEqual(try behavior(responseTaskResponse), "deny")
    }

    /// Three WebFetches to new sites in one message, two of them waiting:
    /// approving the first lets it run, and its PostToolUse must not take the
    /// second with it.
    func testOneParallelRequestsPostToolUseLeavesTheOtherWaiting() async throws {
        let appState = AppState()
        let a: [String: Any] = ["url": "https://a.example", "prompt": "read"]
        let b: [String: Any] = ["url": "https://b.example", "prompt": "read"]
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "WebFetch", toolUseId: "toolu_a", toolInput: a))
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "WebFetch", toolUseId: "toolu_b", toolInput: b))
        let requestA = try makeHookEvent(name: "PermissionRequest", sessionId: "s1", toolName: "WebFetch", toolUseId: nil, toolInput: a)
        let requestB = try makeHookEvent(name: "PermissionRequest", sessionId: "s1", toolName: "WebFetch", toolUseId: nil, toolInput: b)
        let taskA = await startHookRequest { appState.handlePermissionRequest(requestA, continuation: $0) }
        let taskB = await startHookRequest { appState.handlePermissionRequest(requestB, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.map(\.toolUseId), ["toolu_a", "toolu_b"])

        appState.approvePermission()
        let taskAResponse = try await awaitValue(of: taskA)
        XCTAssertEqual(try behavior(taskAResponse), "allow")
        appState.handleEvent(try makeHookEvent(name: "PostToolUse", sessionId: "s1", toolName: "WebFetch", toolUseId: "toolu_a", toolInput: a))

        XCTAssertEqual(appState.permissionQueue.map(\.toolUseId), ["toolu_b"])
        await assertStillPending(taskB)
        appState.denyPermission()
        let taskBResponse = try await awaitValue(of: taskB)
        XCTAssertEqual(try behavior(taskBResponse), "deny")
    }

    /// Codex's PermissionRequest adds `tool_input.description` (the approval
    /// reason), which its PreToolUse does not have. It is still the same call.
    func testCodexRequestMatchesItsPreToolUseDespiteTheApprovalReason() async throws {
        let appState = AppState()
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "call_push", toolInput: ["command": "git push"]))
        let request = try makeHookEvent(
            name: "PermissionRequest", sessionId: "s1", toolName: "Bash", toolUseId: nil,
            toolInput: ["command": "git push", "description": "Needs network access"]
        )
        let responseTask = await startHookRequest { appState.handlePermissionRequest(request, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.first?.toolUseId, "call_push")

        appState.denyPermission()
        _ = try await awaitValue(of: responseTask)
    }

    /// Two identical calls in flight cannot be told apart, so neither request
    /// is pinned to one, and one of them finishing answers neither.
    func testIdenticalParallelCallsAreNotGuessedApart() async throws {
        let appState = AppState()
        let input: [String: Any] = ["command": "make test"]
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1", toolInput: input))
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_2", toolInput: input))
        let request = try makeHookEvent(name: "PermissionRequest", sessionId: "s1", toolName: "Bash", toolUseId: nil, toolInput: input)
        let first = await startHookRequest { appState.handlePermissionRequest(request, continuation: $0) }
        let second = await startHookRequest { appState.handlePermissionRequest(request, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.map(\.toolUseId), [nil, nil])

        appState.approvePermission()
        _ = try await awaitValue(of: first)
        appState.handleEvent(try makeHookEvent(name: "PostToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1", toolInput: input))
        XCTAssertEqual(appState.permissionQueue.count, 1, "the other identical call still waits for you")
        await assertStillPending(second)

        appState.denyPermission()
        _ = try await awaitValue(of: second)
    }

    /// Two identical calls both answered in the terminal: each one's
    /// PostToolUse takes one card down. A card beyond the identical calls
    /// still in flight belongs to the call that just posted.
    func testIdenticalCallsAnsweredInTheTerminalLeaveOneByOne() async throws {
        let appState = AppState()
        let input: [String: Any] = ["command": "make test"]
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1", toolInput: input))
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_2", toolInput: input))
        let request = try makeHookEvent(name: "PermissionRequest", sessionId: "s1", toolName: "Bash", toolUseId: nil, toolInput: input)
        let first = await startHookRequest { appState.handlePermissionRequest(request, continuation: $0) }
        let second = await startHookRequest { appState.handlePermissionRequest(request, continuation: $0) }

        appState.handleEvent(try makeHookEvent(name: "PostToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1", toolInput: input))
        let firstResponse = try await awaitValue(of: first)
        XCTAssertNil(try decisionBehavior(firstResponse), "let go, not answered for you")
        XCTAssertEqual(appState.permissionQueue.count, 1)
        await assertStillPending(second)

        appState.handleEvent(try makeHookEvent(name: "PostToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_2", toolInput: input))
        let secondResponse = try await awaitValue(of: second)
        XCTAssertNil(try decisionBehavior(secondResponse))
        XCTAssertTrue(appState.permissionQueue.isEmpty)
    }

    /// A call you deny never runs, so it never posts. Its PreToolUse must not
    /// linger and make Claude's retry of the same command look ambiguous.
    func testADeniedCallDoesNotBlurItsRetry() async throws {
        let appState = AppState()
        let input: [String: Any] = ["command": "rm -rf dist"]
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1", toolInput: input))
        let request = try makeHookEvent(name: "PermissionRequest", sessionId: "s1", toolName: "Bash", toolUseId: nil, toolInput: input)
        let first = await startHookRequest { appState.handlePermissionRequest(request, continuation: $0) }
        appState.denyPermission()
        _ = try await awaitValue(of: first)

        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_2", toolInput: input))
        let retry = await startHookRequest { appState.handlePermissionRequest(request, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.first?.toolUseId, "toolu_2")

        appState.denyPermission()
        _ = try await awaitValue(of: retry)
    }

    // MARK: - Health check 2026-11-04 #2: OpenCode names the request it answered

    /// OpenCode can hold two approvals in one conversation. Answering one in its
    /// TUI (rejecting counts) used to send an id-less PostToolUse that let the
    /// other through as "allow". Its reply now names the request, and only that
    /// one is let go — with no decision, so the plugin replies nothing for it.
    func testOpenCodeReplySettlesOnlyTheRequestItNames() async throws {
        let appState = AppState()
        let ls = try openCodeRequest("per_ls", tool: "Bash", input: ["command": "ls"])
        let rm = try openCodeRequest("per_rm", tool: "Bash", input: ["command": "rm -rf dist"])
        let lsTask = await startHookRequest { appState.handlePermissionRequest(ls, continuation: $0) }
        let rmTask = await startHookRequest { appState.handlePermissionRequest(rm, continuation: $0) }

        appState.handleEvent(try openCodeReply("per_ls"))

        let lsTaskResponse = try await awaitValue(of: lsTask)
        XCTAssertNil(try decisionBehavior(lsTaskResponse))
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.permissionQueue.first?.event.rawJSON["_opencode_request_id"] as? String, "per_rm")
        await assertStillPending(rmTask)

        appState.handleEvent(try openCodeReply("per_other"))
        XCTAssertEqual(appState.permissionQueue.count, 1, "a reply for a request Burrow does not hold changes nothing")

        appState.denyPermission()
        let rmTaskResponse = try await awaitValue(of: rmTask)
        XCTAssertEqual(try behavior(rmTaskResponse), "deny")
    }

    /// The question side: `question.replied` for another request leaves an
    /// OpenCode question card alone; its own reply takes it down.
    func testOpenCodeReplySettlesOnlyTheQuestionItNames() async throws {
        let appState = AppState()
        let ask = try openCodeRequest(
            "que_1", tool: "AskUserQuestion",
            input: ["questions": [["question": "Which?", "options": [["label": "A"], ["label": "B"]]]]]
        )
        let askTask = await startHookRequest { appState.handleAskUserQuestion(ask, continuation: $0) }
        XCTAssertEqual(appState.questionQueue.count, 1)

        appState.handleEvent(try openCodeReply("per_other"))
        XCTAssertEqual(appState.questionQueue.count, 1)
        await assertStillPending(askTask)

        appState.handleEvent(try openCodeReply("que_1"))
        let askTaskResponse = try await awaitValue(of: askTask)
        XCTAssertNil(try decisionBehavior(askTaskResponse))
        XCTAssertTrue(appState.questionQueue.isEmpty)
    }

    private func openCodeRequest(_ id: String, tool: String, input: [String: Any]) throws -> HookEvent {
        try makeRawHookEvent([
            "hook_event_name": "PermissionRequest", "session_id": "opencode-ses_1", "_source": "opencode",
            "tool_name": tool, "tool_input": input, "_opencode_request_id": id,
        ])
    }

    private func openCodeReply(_ id: String) throws -> HookEvent {
        try makeRawHookEvent([
            "hook_event_name": "PostToolUse", "session_id": "opencode-ses_1", "_source": "opencode",
            "_opencode_request_id": id,
        ])
    }

    /// Guard for #147 inside the #216 fix: an orphan-drain triggered by a follow-up
    /// activity event must NOT touch permission requests that carry a tool_use_id —
    /// those still wait for proper correlation so parallel tool calls don't deny
    /// each other.
    func testOrphanDrainDoesNotResolvePermissionWithToolUseId() async throws {
        let appState = AppState()
        let correlated = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "toolu_keep")

        let responseTask = await startHookRequest { appState.handlePermissionRequest(correlated, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)

        // Unrelated follow-up activity (different/absent tool_use_id) for the same
        // session. The correlated request keeps waiting.
        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_other"
        ))

        XCTAssertEqual(appState.permissionQueue.count, 1,
            "Permission with a tool_use_id must not be drained by an unrelated follow-up (#147)")
        XCTAssertEqual(appState.permissionQueue.first?.toolUseId, "toolu_keep")
        await assertStillPending(responseTask)

        appState.approvePermission()
        let response = try await awaitValue(of: responseTask)
        XCTAssertEqual(try behavior(response), "allow")
    }

    // MARK: - issue #147 regression: parallel/plugin tool calls must not deny pending permissions

    /// Repro for #147: a Stop (or any non-keepWaiting activity event) arriving
    /// while a PermissionRequest is pending used to trigger a wasWaiting blanket
    /// drain that denied the queued request before the user could react.
    /// After the fix, only surgical (tool_use_id) drains may remove a queued
    /// permission — unrelated activity events leave the queue alone.
    func testStopEventDoesNotDenyPendingPermission() async throws {
        let appState = AppState()
        let pending = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "toolu_keep")

        let responseTask = await startHookRequest { appState.handlePermissionRequest(pending, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.sessions["s1"]?.status, .waitingApproval)

        // Activity event for the same session that carries no tool_use_id.
        // Pre-fix this would blanket-drain the pending permission via the
        // wasWaiting branch in handleEvent.
        appState.handleEvent(try makeHookEvent(
            name: "Stop",
            sessionId: "s1",
            toolName: nil,
            toolUseId: nil
        ))

        XCTAssertEqual(appState.permissionQueue.count, 1, "Stop must not deny a pending PermissionRequest with a different/absent tool_use_id (#147)")
        await assertStillPending(responseTask)

        appState.approvePermission()
        let response = try await awaitValue(of: responseTask)
        XCTAssertEqual(try behavior(response), "allow")
    }

    /// Repro for #147 with parallel tools: Notion / MCP plugin invokes two
    /// fetches at once. Tool A finishes while tool B's PermissionRequest is
    /// still pending. Pre-fix, the blanket drain denied B; the UI flashed a card
    /// and users saw "denied by PermissionRequest hook" before they could react.
    /// The request is built the way Claude Code sends it — no tool_use_id — and
    /// finds B's id through B's PreToolUse.
    func testParallelPostToolUseDoesNotDenyUnrelatedPendingPermission() async throws {
        let appState = AppState()
        let fetchA: [String: Any] = ["id": "page-a"]
        let fetchB: [String: Any] = ["id": "page-b"]
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "mcp__notion__notion-fetch", toolUseId: "toolu_A", toolInput: fetchA))
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "mcp__notion__notion-fetch", toolUseId: "toolu_B", toolInput: fetchB))
        let pendingForToolB = try makeHookEvent(
            name: "PermissionRequest",
            sessionId: "s1",
            toolName: "mcp__notion__notion-fetch",
            toolUseId: nil,
            toolInput: fetchB
        )

        let responseTask = await startHookRequest { appState.handlePermissionRequest(pendingForToolB, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)

        // Tool A finishes.
        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "mcp__notion__notion-fetch",
            toolUseId: "toolu_A",
            toolInput: fetchA
        ))

        XCTAssertEqual(appState.permissionQueue.count, 1,
            "Unrelated PostToolUse must not deny pending PermissionRequest for parallel tool (#147)")
        XCTAssertEqual(appState.permissionQueue.first?.toolUseId, "toolu_B")
        await assertStillPending(responseTask)

        appState.approvePermission()
        let response = try await awaitValue(of: responseTask)
        XCTAssertEqual(try behavior(response), "allow")
    }

    /// A background subagent shares its parent's session_id. Its PostToolUse /
    /// SubagentStop arriving while the main thread's AskUserQuestion is on screen
    /// used to blanket-drain the question, so Claude saw "Permission denied by hook".
    /// The main thread's own PostToolUse (answered in the terminal) still drains it.
    func testSubagentActivityDoesNotDenyMainThreadQuestion() async throws {
        let appState = AppState()
        let ask = try makeRawHookEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Fix it?", "options": [["label": "Yes"], ["label": "No"]]]]],
        ])
        let responseTask = await startHookRequest { appState.handleAskUserQuestion(ask, continuation: $0) }
        XCTAssertEqual(appState.questionQueue.count, 1)

        for name in ["PostToolUse", "SubagentStop"] {
            appState.handleEvent(try makeRawHookEvent([
                "hook_event_name": name,
                "session_id": "s1",
                "agent_id": "bg-agent",
                "tool_name": "Bash",
                "tool_use_id": "toolu_bg_\(name)",
            ]))
        }
        XCTAssertEqual(appState.questionQueue.count, 1, "subagent activity must not drain the parent's question")
        await assertStillPending(responseTask)

        appState.handleEvent(try makeHookEvent(name: "PostToolUse", sessionId: "s1", toolName: "AskUserQuestion", toolUseId: "toolu_ask"))
        XCTAssertTrue(appState.questionQueue.isEmpty, "main-thread activity still means the question was answered elsewhere")
        _ = try await awaitValue(of: responseTask)
    }

    /// The other per-session drains had the same blind spot: a subagent's new
    /// permission request, its own question, or its hook socket dropping each
    /// denied the main thread's pending question.
    func testSubagentRequestsAndDisconnectsDoNotDenyMainThreadQuestion() async throws {
        let appState = AppState()
        let mainAsk = try makeAskEvent(agentId: nil)
        let mainResponse = await startHookRequest { appState.handleAskUserQuestion(mainAsk, continuation: $0) }

        let subBash = try makeRawHookEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "agent_id": "bg-agent",
            "tool_name": "Bash",
            "tool_use_id": "toolu_sub_bash",
        ])
        let subPermission = await startHookRequest { appState.handlePermissionRequest(subBash, continuation: $0) }
        XCTAssertEqual(appState.questionQueue.map(\.event.agentId), [nil], "a subagent's permission request must not deny the parent's question")
        XCTAssertEqual(appState.permissionQueue.count, 1)

        let subAsk = try makeAskEvent(agentId: "bg-agent")
        let subQuestion = await startHookRequest { appState.handleAskUserQuestion(subAsk, continuation: $0) }

        // A new question from the subagent still supersedes that subagent's own
        // permission request, but leaves the parent's question alone.
        _ = try await awaitValue(of: subPermission)
        XCTAssertTrue(appState.permissionQueue.isEmpty)
        XCTAssertEqual(appState.questionQueue.map(\.event.agentId), [nil, "bg-agent"])
        await assertStillPending(mainResponse)

        // The subagent's hook socket drops: only its own request goes.
        appState.handlePeerDisconnect(sessionId: "s1", agentId: "bg-agent")
        _ = try await awaitValue(of: subQuestion)
        XCTAssertEqual(appState.questionQueue.map(\.event.agentId), [nil])
        XCTAssertEqual(appState.sessions["s1"]?.status, .waitingQuestion)
        await assertStillPending(mainResponse)

        appState.handlePeerDisconnect(sessionId: "s1")
        _ = try await awaitValue(of: mainResponse)
        XCTAssertTrue(appState.questionQueue.isEmpty)
    }

    private func makeAskEvent(agentId: String?) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Fix it?", "options": [["label": "Yes"], ["label": "No"]]]]],
        ]
        if let agentId { payload["agent_id"] = agentId }
        return try makeRawHookEvent(payload)
    }


    // MARK: - Backfill from cache

    func testEnrichBackfillsMissingToolNameFromCache() async throws {
        let appState = AppState()
        appState.handleEvent(try makeHookEvent(
            name: "PreToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_enrich",
            toolInput: ["command": "ls"]
        ))

        // PermissionRequest payload omits tool_name (simulates a thin third-party re-emit).
        let thin = try makeRawHookEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_use_id": "toolu_enrich"
        ])

        // Check once the handler has actually run: a bare Task was never
        // scheduled before this synchronous test read the session.
        let response = await startHookRequest { appState.handlePermissionRequest(thin, continuation: $0) }
        let session = appState.sessions["s1"]
        XCTAssertEqual(session?.currentTool, "Bash")

        appState.handlePeerDisconnect(sessionId: "s1")
        _ = try await awaitValue(of: response)
    }

    // MARK: - Helpers

    private func makeHookEvent(
        name: String,
        sessionId: String,
        toolName: String?,
        toolUseId: String?,
        toolInput: [String: Any]? = nil,
        source: String? = nil
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": name,
            "session_id": sessionId
        ]
        if let toolName { payload["tool_name"] = toolName }
        if let toolUseId { payload["tool_use_id"] = toolUseId }
        if let toolInput { payload["tool_input"] = toolInput }
        if let source { payload["_source"] = source }
        return try makeRawHookEvent(payload)
    }

    private func makePermissionEvent(sessionId: String, toolName: String, toolUseId: String, source: String? = nil) throws -> HookEvent {
        try makeHookEvent(
            name: "PermissionRequest",
            sessionId: sessionId,
            toolName: toolName,
            toolUseId: toolUseId,
            toolInput: ["command": "echo hi"],
            source: source
        )
    }

    private func makeRawHookEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("HookEvent should decode payload: \(payload)")
            throw NSError(domain: "AppStateToolUseCacheTests", code: 1)
        }
        return event
    }

    /// The decision's behavior, or nil when Burrow let go without one.
    private func decisionBehavior(_ data: Data) throws -> String? {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hookSpecific = json["hookSpecificOutput"] as? [String: Any]
        let decision = hookSpecific?["decision"] as? [String: Any]
        return decision?["behavior"] as? String
    }

    private func behavior(_ data: Data) throws -> String {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hookSpecific = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecific["decision"] as? [String: Any])
        return try XCTUnwrap(decision["behavior"] as? String)
    }
}
