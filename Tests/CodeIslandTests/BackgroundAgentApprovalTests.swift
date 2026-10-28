import XCTest
import CodeIslandCore
@testable import CodeIsland

/// design/v20 review: one of Claude Code's own background agents asks for
/// approval after the conversation's turn is over. Once it is answered the
/// conversation is done again, not "working on Agent" for good.
@MainActor
final class BackgroundAgentApprovalTests: XCTestCase {
    private func event(_ payload: [String: Any]) throws -> HookEvent {
        var payload = payload
        payload["session_id"] = "s1"
        payload["_source"] = "claude"
        return try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
    }

    private func finishedConversation() -> AppState {
        let appState = AppState()
        var s = SessionSnapshot()
        s.source = "claude"
        s.status = .idle
        s.lastAssistantMessage = "做完了"
        appState.sessions["s1"] = s
        return appState
    }

    func testAnsweringABackgroundAgentLeavesTheConversationDone() async throws {
        for approve in [true, false] {
            let appState = finishedConversation()
            appState.handleEvent(try event(["hook_event_name": "SubagentStart", "agent_id": "bg", "agent_type": "general-purpose"]))
            let request = try event([
                "hook_event_name": "PermissionRequest", "agent_id": "bg",
                "tool_name": "Bash", "tool_input": ["command": "rm -rf tmp"],
            ])
            let response = await startHookRequest { appState.handlePermissionRequest(request, continuation: $0) }
            XCTAssertEqual(appState.sessions["s1"]?.status, .waitingApproval, "the request still needs you")

            if approve { appState.approvePermission() } else { appState.denyPermission() }
            _ = try await awaitValue(of: response)
            XCTAssertEqual(appState.sessions["s1"]?.status, .idle, approve ? "approved" : "denied")
            XCTAssertNil(appState.sessions["s1"]?.currentTool)

            appState.handleEvent(try event(["hook_event_name": "SubagentStop", "agent_id": "bg"]))
            XCTAssertEqual(appState.sessions["s1"]?.status, .idle)
        }
    }
}
