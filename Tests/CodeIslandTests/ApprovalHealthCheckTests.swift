import XCTest
import CodeIslandCore
@testable import CodeIsland

/// The approval items of the 2026-11-04 health check
/// (design/体检-2026-11-04/README.md): #3, #6, #16 and #17. #1 and #2 live in
/// AppStateToolUseCacheTests, #7 in CommandGistTests, #10 in DangerousCommandTests.
@MainActor
final class ApprovalHealthCheckTests: XCTestCase {

    // MARK: - #3: a card waiting on you never times out on its own

    /// The hook waits up to 86400 s (ConfigInstaller) and so does the bridge's
    /// socket; HookServer used to cancel a still-waiting connection after five
    /// minutes, which Burrow took as "answered elsewhere": the card vanished
    /// while the agent still waited. A waiting connection now ends only when
    /// Burrow answers it or its peer goes away.
    func testHookServerDoesNotCutOffAConnectionThatWaitsForYou() throws {
        let source = try String(contentsOf: Self.sourceFile("Sources/CodeIsland/HookServer.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func monitorPeerDisconnect("))
        let end = try XCTUnwrap(source.range(of: "private func sendResponse(", range: start.upperBound..<source.endIndex))
        let monitor = source[start.lowerBound..<end.lowerBound]
        XCTAssertFalse(monitor.contains("Task.sleep"), "no timer may end a connection that waits for the user")
        XCTAssertFalse(monitor.contains("connection.cancel()"), "only the answer or the peer ends a waiting connection")
    }

    // MARK: - #6: a dropped connection takes only its own request

    /// Two requests of one conversation and agent, each on its own socket. The
    /// first socket closes (answered in Claude, or its bridge died): that one
    /// request goes, the second still waits for you instead of being denied.
    func testOneDroppedConnectionSettlesOnlyItsOwnRequest() async throws {
        let appState = AppState()
        let connA = UUID(), connB = UUID()
        let a = try event(["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "ls"]])
        let b = try event(["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "rm -rf dist"]])
        let taskA = await startHookRequest { appState.handlePermissionRequest(a, connectionId: connA, continuation: $0) }
        let taskB = await startHookRequest { appState.handlePermissionRequest(b, connectionId: connB, continuation: $0) }

        appState.handlePeerDisconnect(sessionId: "s1", agentId: nil, connectionId: connA)

        _ = try await awaitValue(of: taskA)
        XCTAssertEqual(appState.permissionQueue.map { $0.event.toolInput?["command"] as? String }, ["rm -rf dist"])
        XCTAssertEqual(appState.sessions["s1"]?.status, .waitingApproval)
        await assertStillPending(taskB)

        appState.approvePermission()
        let taskBResponse = try await awaitValue(of: taskB)
        XCTAssertEqual(try behavior(taskBResponse), "allow", "you answer B yourself")
    }

    /// A conversation you hid stays hidden when one of its requests' sockets
    /// closes and another request is still queued.
    func testADroppedConnectionDoesNotUnhideTheConversationsOtherRequest() async throws {
        let appState = AppState()
        let connA = UUID(), connB = UUID()
        let a = try event(["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "ls"]])
        let b = try event(["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "pwd"]])
        let taskA = await startHookRequest { appState.handlePermissionRequest(a, connectionId: connA, continuation: $0) }
        appState.dismissPermissionPrompt()
        let taskB = await startHookRequest { appState.handlePermissionRequest(b, connectionId: connB, continuation: $0) }
        appState.dismissPermissionPrompt()
        XCTAssertTrue(appState.visiblePermissionSessionIds.isEmpty)

        appState.handlePeerDisconnect(sessionId: "s1", agentId: nil, connectionId: connA)
        _ = try await awaitValue(of: taskA)

        XCTAssertTrue(appState.visiblePermissionSessionIds.isEmpty, "still hidden")
        XCTAssertNotEqual(appState.surface, .approvalCard(sessionId: "s1"))
        appState.handlePeerDisconnect(sessionId: "s1", agentId: nil, connectionId: connB)
        _ = try await awaitValue(of: taskB)
    }

    /// Questions are tied to their socket the same way.
    func testADroppedConnectionTakesOnlyItsOwnQuestion() async throws {
        let appState = AppState()
        let conn = UUID()
        let ask = try event([
            "hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Ship it?", "options": [["label": "Yes"], ["label": "No"]]]]],
        ])
        let task = await startHookRequest { appState.handleAskUserQuestion(ask, connectionId: conn, continuation: $0) }

        appState.handlePeerDisconnect(sessionId: "s1", agentId: nil, connectionId: UUID())
        XCTAssertEqual(appState.questionQueue.count, 1, "another socket closing is not this question's")
        await assertStillPending(task)

        appState.handlePeerDisconnect(sessionId: "s1", agentId: nil, connectionId: conn)
        _ = try await awaitValue(of: task)
        XCTAssertTrue(appState.questionQueue.isEmpty)
    }

    // MARK: - #16: "N/M" counts only what you can still see

    /// A conversation you hid is not counted: the card said "1/2", folded
    /// after your answer, and the second never came.
    func testCardCountLeavesOutAConversationYouHid() async throws {
        let appState = AppState()
        let s1 = await request(appState, session: "s1", command: "ls")
        let s2 = await request(appState, session: "s2", command: "pwd")
        XCTAssertEqual(appState.permissionCardCount(forSession: "s1"), .init(position: 1, total: 2))
        XCTAssertEqual(appState.permissionCardCount(forSession: "s2"), .init(position: 2, total: 2))

        appState.dismissPermissionPrompt(expectedSessionId: "s1")
        XCTAssertEqual(appState.permissionCardCount(forSession: "s2"), .init(position: 1, total: 1))

        appState.handlePeerDisconnect(sessionId: "s1")
        appState.handlePeerDisconnect(sessionId: "s2")
        _ = try await awaitValue(of: s1)
        _ = try await awaitValue(of: s2)
    }

    /// Two requests of one conversation are two cards to answer.
    func testCardCountCountsEachRequestOfAConversation() async throws {
        let appState = AppState()
        let a = await request(appState, session: "s1", command: "ls")
        let b = await request(appState, session: "s1", command: "pwd")
        XCTAssertEqual(appState.permissionCardCount(forSession: "s1"), .init(position: 1, total: 2))
        appState.handlePeerDisconnect(sessionId: "s1")
        _ = try await awaitValue(of: a)
        _ = try await awaitValue(of: b)
    }

    func testQuestionCardCountLeavesOutAQuestionYouClosed() async throws {
        let appState = AppState()
        let q1 = await question(appState, session: "s1")
        let q2 = await question(appState, session: "s2")
        XCTAssertEqual(appState.questionCardCount(forSession: "s2"), .init(position: 2, total: 2))

        appState.dismissQuestion(expectedSessionId: "s1")
        XCTAssertEqual(appState.questionCardCount(forSession: "s2"), .init(position: 1, total: 1))

        appState.handlePeerDisconnect(sessionId: "s1")
        appState.handlePeerDisconnect(sessionId: "s2")
        _ = try await awaitValue(of: q1)
        _ = try await awaitValue(of: q2)
    }

    // MARK: - Helpers

    private func request(_ appState: AppState, session: String, command: String) async -> Task<Data, Never> {
        let e = try! event(["hook_event_name": "PermissionRequest", "session_id": session,
                            "tool_name": "Bash", "tool_input": ["command": command]])
        return await startHookRequest { appState.handlePermissionRequest(e, continuation: $0) }
    }

    private func question(_ appState: AppState, session: String) async -> Task<Data, Never> {
        let e = try! event([
            "hook_event_name": "PermissionRequest", "session_id": session, "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Which?", "options": [["label": "A"], ["label": "B"]]]]],
        ])
        return await startHookRequest { appState.handleAskUserQuestion(e, continuation: $0) }
    }

    private func event(_ payload: [String: Any]) throws -> HookEvent {
        var payload = payload
        payload["session_id"] = payload["session_id"] ?? "s1"
        return try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
    }

    private func behavior(_ data: Data) throws -> String? {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decision = (json["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        return decision?["behavior"] as? String
    }

    /// The repository file at `path`, found from this test file's location.
    static func sourceFile(_ path: String, from file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()  // CodeIslandTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository
            .appendingPathComponent(path)
    }
}
