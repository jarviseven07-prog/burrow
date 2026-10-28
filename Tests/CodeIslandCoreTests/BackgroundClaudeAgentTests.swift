import XCTest
@testable import CodeIslandCore

/// Claude Code runs agents of its own once a turn is over. Seen on
/// 2026-10-28: two finished conversations sat on "thinking" for good after
/// one such agent started and stopped, because their CLIs were alive and
/// nothing timed them out.
final class BackgroundClaudeAgentTests: XCTestCase {
    private let id = "claude-session"
    private let finishedAt = Date(timeIntervalSince1970: 1_000)

    private func send(_ payload: [String: Any], to sessions: inout [String: SessionSnapshot]) throws -> [SideEffect] {
        var payload = payload
        payload["session_id"] = id
        payload["_source"] = payload["_source"] ?? "claude"
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try XCTUnwrap(HookEvent(from: data))
        return reduceEvent(sessions: &sessions, event: event, maxHistory: 10)
    }

    private func parent(source: String = "claude", status: AgentStatus) -> [String: SessionSnapshot] {
        var s = SessionSnapshot()
        s.source = source
        s.status = status
        s.lastActivity = finishedAt
        s.lastAssistantMessage = "做完了"
        return [id: s]
    }

    func testAnAgentAfterTheTurnLeavesTheConversationAsItWas() throws {
        var sessions = parent(status: .idle)
        var effects: [SideEffect] = []
        for payload: [String: Any] in [
            ["hook_event_name": "SubagentStart", "agent_id": "bg-1", "agent_type": "general-purpose"],
            ["hook_event_name": "PreToolUse", "agent_id": "bg-1", "tool_name": "Write", "tool_input": ["file_path": "/tmp/m.md"]],
            ["hook_event_name": "PostToolUse", "agent_id": "bg-1", "tool_name": "Write"],
            ["hook_event_name": "SubagentStop", "agent_id": "bg-1"],
        ] {
            effects += try send(payload, to: &sessions)
            XCTAssertEqual(sessions[id]?.status, .idle, "\(payload["hook_event_name"]!)")
        }
        XCTAssertNil(sessions[id]?.currentTool)
        XCTAssertEqual(sessions[id]?.lastActivity, finishedAt, "the row's time stays the turn's")
        XCTAssertTrue(effects.isEmpty, "no focus moves to it")
        XCTAssertTrue(sessions[id]?.subagents.isEmpty == true)
    }

    func testABackgroundAgentStillRunningDoesNotHoldTheNextTurnOpen() throws {
        var sessions = parent(status: .idle)
        _ = try send(["hook_event_name": "SubagentStart", "agent_id": "bg-1", "agent_type": "general-purpose"], to: &sessions)
        XCTAssertEqual(sessions[id]?.subagents["bg-1"]?.outsideParentTurn, true)
        _ = try send(["hook_event_name": "UserPromptSubmit", "prompt": "再看一下"], to: &sessions)
        XCTAssertEqual(sessions[id]?.status, .processing)
        _ = try send(["hook_event_name": "Stop"], to: &sessions)
        XCTAssertEqual(sessions[id]?.status, .idle)
        // Its later hooks still leave the finished turn alone.
        _ = try send(["hook_event_name": "SubagentStop", "agent_id": "bg-1"], to: &sessions)
        XCTAssertEqual(sessions[id]?.status, .idle)
    }

    /// A Task the conversation started keeps the card working, as before.
    func testATaskDuringTheTurnStillShowsAsWork() throws {
        var sessions = parent(status: .running)
        _ = try send(["hook_event_name": "SubagentStart", "agent_id": "task-1", "agent_type": "Explore"], to: &sessions)
        XCTAssertEqual(sessions[id]?.subagents["task-1"]?.outsideParentTurn, false)
        _ = try send(["hook_event_name": "Stop"], to: &sessions)
        XCTAssertEqual(sessions[id]?.status, .running, "the parent waits on its Task")
        _ = try send(["hook_event_name": "SubagentStop", "agent_id": "task-1"], to: &sessions)
        XCTAssertEqual(sessions[id]?.status, .processing)
    }

    func testOtherAgentsAreUnchanged() throws {
        var sessions = parent(source: "codex", status: .idle)
        _ = try send(["hook_event_name": "SubagentStart", "agent_id": "worker-1", "agent_type": "worker", "_source": "codex"], to: &sessions)
        XCTAssertEqual(sessions[id]?.status, .running)
    }
}
