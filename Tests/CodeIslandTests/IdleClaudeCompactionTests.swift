import XCTest
import CodeIslandCore
@testable import CodeIsland

/// Claude Code compacts a finished conversation on its own about 55 minutes
/// after its last turn: PreCompact(auto), then the compacting agent's
/// SubagentStop, and nothing after. On 11-02 five finished chats got
/// "Compacting context…" from the PreCompact, the silent-thinking sweep skipped
/// rows with a note, and they sat on "thinking" in the den for hours.
/// The payloads below are those hooks as the bridge logged them.
@MainActor
final class IdleClaudeCompactionTests: XCTestCase {
    private let id = "1780bce2-8006-47ba-a162-f4ec6a12fc39"

    private func event(_ json: String) -> HookEvent {
        HookEvent(from: Data(json.utf8))!
    }

    private var preCompact: HookEvent {
        event(#"{"session_id":"1780bce2-8006-47ba-a162-f4ec6a12fc39","prompt_id":"245d116b","hook_event_name":"PreCompact","trigger":"auto","custom_instructions":null,"_source":"claude","cwd":"/tmp/burrow"}"#)
    }

    private var compactorStop: HookEvent {
        event(#"{"session_id":"1780bce2-8006-47ba-a162-f4ec6a12fc39","prompt_id":"245d116b","permission_mode":"auto","agent_id":"a740e30d77dcb1e80","agent_type":"","hook_event_name":"SubagentStop","stop_hook_active":false,"last_assistant_message":"<analysis>…","background_tasks":[],"session_crons":[],"_source":"claude","cwd":"/tmp/burrow"}"#)
    }

    private func finishedRow(_ app: AppState, at finishedAt: Date) {
        var s = SessionSnapshot()
        s.source = "claude"
        s.status = .idle
        s.lastAssistantMessage = "修好了"
        s.lastActivity = finishedAt
        app.sessions[id] = s
    }

    func testCompactingAFinishedConversationLeavesItFinished() {
        let app = AppState()
        let finishedAt = Date().addingTimeInterval(-60)
        finishedRow(app, at: finishedAt)
        app.handleEvent(preCompact)
        app.handleEvent(compactorStop)
        XCTAssertEqual(app.sessions[id]?.status, .idle)
        XCTAssertNil(app.sessions[id]?.toolDescription)
        XCTAssertEqual(app.sessions[id]?.lastActivity, finishedAt, "it still leaves three minutes after its turn")
    }

    func testCompactingAConversationTheDenDoesNotShowBringsNoRow() {
        let app = AppState()
        app.handleEvent(preCompact)
        app.handleEvent(compactorStop)
        XCTAssertNil(app.sessions[id])
    }

    func testAManualCompactAndOneInsideATurnStillShow() {
        let app = AppState()
        finishedRow(app, at: Date())
        app.handleEvent(event(#"{"session_id":"1780bce2-8006-47ba-a162-f4ec6a12fc39","hook_event_name":"PreCompact","trigger":"manual","_source":"claude","cwd":"/tmp/burrow"}"#))
        XCTAssertEqual(app.sessions[id]?.status, .processing)

        app.sessions[id]?.status = .running
        app.handleEvent(preCompact)
        XCTAssertEqual(app.sessions[id]?.status, .processing, "auto compact mid-turn")
    }

    func testOnlyClaudesIdleCompactionIsIgnored() {
        let auto: [String: Any] = ["_source": "claude", "trigger": "auto"]
        var idle = SessionSnapshot()
        idle.status = .idle
        var working = idle
        working.status = .processing
        XCTAssertTrue(AppState.isIdleClaudeCompaction(normalizedEventName: "PreCompact", rawJSON: auto, session: nil))
        XCTAssertTrue(AppState.isIdleClaudeCompaction(normalizedEventName: "PreCompact", rawJSON: auto, session: idle))
        XCTAssertFalse(AppState.isIdleClaudeCompaction(normalizedEventName: "PreCompact", rawJSON: auto, session: working))
        XCTAssertFalse(AppState.isIdleClaudeCompaction(normalizedEventName: "PreCompact",
                                                       rawJSON: ["_source": "claude", "trigger": "manual"], session: idle))
        XCTAssertFalse(AppState.isIdleClaudeCompaction(normalizedEventName: "PreCompact",
                                                       rawJSON: ["_source": "codex", "trigger": "auto"], session: nil))
        XCTAssertTrue(AppState.isIdleClaudeCompaction(normalizedEventName: "SubagentStop", rawJSON: ["_source": "claude"], session: nil))
        XCTAssertFalse(AppState.isIdleClaudeCompaction(normalizedEventName: "SubagentStop", rawJSON: ["_source": "claude"], session: idle))
    }

    /// The sweep judges a thinking Claude row by its transcript even with a
    /// note on it; a running tool is never timed out while its process lives.
    func testTheSweepJudgesThinkingClaudeRowsWithANote() {
        var claude = SessionSnapshot()
        claude.source = "claude"
        claude.status = .processing
        claude.toolDescription = "Compacting context…"
        XCTAssertTrue(AppState.sweepsSilentThinking(claude))

        var tool = claude
        tool.status = .running
        tool.currentTool = "Bash"
        XCTAssertFalse(AppState.sweepsSilentThinking(tool))

        var codex = claude
        codex.source = "codex"
        XCTAssertFalse(AppState.sweepsSilentThinking(codex))
        codex.toolDescription = nil
        XCTAssertTrue(AppState.sweepsSilentThinking(codex))
    }
}
