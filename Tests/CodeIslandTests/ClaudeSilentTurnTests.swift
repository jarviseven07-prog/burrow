import XCTest
@testable import CodeIsland
import CodeIslandCore

/// A Claude turn can be silent for minutes — thinking, or streaming one big
/// Write — with no hook and no transcript line. The idle sweep used to read
/// that silence as a finished turn (30s for Claude Desktop, which counts as a
/// native app), so a working session slept and its card said done. The sweep
/// now asks the transcript whether the turn is still open.
final class ClaudeSilentTurnTests: XCTestCase {

    private func tail(_ lines: [[String: Any]], cutPrefix: String = "") throws -> Data {
        let body = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        return Data((cutPrefix + "\n" + body.joined(separator: "\n") + "\n").utf8)
    }

    private func assistant(stop: String?, blocks: [String] = ["text"], extra: [String: Any] = [:]) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant", "content": blocks.map { ["type": $0] }]
        message["stop_reason"] = stop ?? NSNull()
        return ["type": "assistant", "message": message].merging(extra) { $1 }
    }

    private func user(_ content: Any) -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content": content]]
    }

    private let toolResult: [[String: Any]] = [["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]

    func testToolResultWithTrailingBookkeepingReadsOpen() throws {
        // The film-demo session: quickstart returned, then the model streamed
        // index.html for minutes. Only attachment/title rows follow the result.
        let data = try tail([
            assistant(stop: "tool_use", blocks: ["tool_use"]),
            user(toolResult),
            ["type": "attachment", "attachment": ["type": "output_style"]],
            ["type": "last-prompt"],
            ["type": "custom-title"],
        ])
        XCTAssertEqual(AppState.claudeTranscriptTurn(tail: data), .open)
    }

    func testPendingToolUseReadsOpen() throws {
        XCTAssertEqual(AppState.claudeTranscriptTurn(tail: try tail([assistant(stop: "tool_use", blocks: ["tool_use"])])), .open)
    }

    func testFreshPromptReadsOpen() throws {
        XCTAssertEqual(AppState.claudeTranscriptTurn(tail: try tail([assistant(stop: "end_turn"), user("next question")])), .open)
    }

    func testEndTurnReadsEnded() throws {
        XCTAssertEqual(AppState.claudeTranscriptTurn(tail: try tail([user("hi"), assistant(stop: "end_turn", blocks: ["thinking"]), assistant(stop: "end_turn")])), .ended)
    }

    func testInterruptMarkerReadsEnded() throws {
        // Esc never fires Stop; the marker is the only trace the turn ended.
        XCTAssertEqual(AppState.claudeTranscriptTurn(tail: try tail([
            assistant(stop: "tool_use", blocks: ["tool_use"]),
            user([["type": "text", "text": "[Request interrupted by user for tool use]"]]),
        ])), .ended)
        XCTAssertEqual(AppState.claudeTranscriptTurn(tail: try tail([user("[Request interrupted by user]")])), .ended)
    }

    func testApiErrorReadsEnded() throws {
        XCTAssertEqual(AppState.claudeTranscriptTurn(tail: try tail([user("hi"), assistant(stop: nil, extra: ["isApiErrorMessage": true])])), .ended)
    }

    func testSidechainAndMetaLinesAreSkipped() throws {
        var meta = user("<local-command-caveat>")
        meta["isMeta"] = true
        let data = try tail([assistant(stop: "end_turn"), assistant(stop: "tool_use", extra: ["isSidechain": true]), meta])
        XCTAssertEqual(AppState.claudeTranscriptTurn(tail: data), .ended)
    }

    func testCutFirstLineAndEmptyTailAreHandled() throws {
        XCTAssertEqual(AppState.claudeTranscriptTurn(tail: try tail([user(toolResult)], cutPrefix: "ssage\":{\"stop_reason\":\"end_turn\"}}")), .open)
        XCTAssertNil(AppState.claudeTranscriptTurn(tail: try tail([["type": "custom-title"]])))
        XCTAssertNil(AppState.claudeTranscriptTurn(atPath: nil))
        XCTAssertNil(AppState.claudeTranscriptTurn(atPath: "/nonexistent/transcript.jsonl"))
    }

    func testReadsFromFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-silent-\(UUID().uuidString).jsonl")
        try tail([assistant(stop: "tool_use", blocks: ["tool_use"]), user(toolResult)]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(AppState.claudeTranscriptTurn(atPath: url.path), .open)
    }

    func testClaudeDesktopSessionIsNativeAppModeAndClaude() {
        // Why the 30s native-app rule caught it: both flags are true.
        var session = SessionSnapshot()
        session.source = "claude"
        session.termBundleId = "com.anthropic.claudefordesktop"
        XCTAssertTrue(session.isNativeAppMode)
        XCTAssertTrue(session.isClaude)
    }
}
