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

    // MARK: Bookkeeping behind the last message (health check #9)

    private func write(_ lines: [[String: Any]]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-turn-\(UUID().uuidString).jsonl")
        try tail(lines).write(to: url)
        return url
    }

    /// Claude Code's own lines, written after every request: a blob of up to
    /// ~300 KB, then a few small ones. With them the last 64 KB held no
    /// message, and the answer was "can't tell".
    private func bookkeeping(blobBytes: Int) -> [[String: Any]] {
        [["type": "api-request-blob", "hash": "h", "message": String(repeating: "x", count: blobBytes)],
         ["type": "api-request", "id": "r1"], ["type": "cost-state", "totalCostUSD": 1], ["type": "last-prompt"]]
    }

    func testAnOpenTurnBehindABigBlobReadsOpen() throws {
        let url = try write([assistant(stop: "tool_use", blocks: ["tool_use"]), user(toolResult)] + bookkeeping(blobBytes: 300_000))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(AppState.claudeTranscriptTurn(tail: try Data(contentsOf: url).suffix(64 * 1024)), "what the 64 KB tail saw")
        XCTAssertEqual(AppState.claudeTranscriptTurn(atPath: url.path), .open)
    }

    func testAnEndedTurnBehindBlobsReadsEnded() throws {
        let url = try write([user("hi"), assistant(stop: "end_turn")] + bookkeeping(blobBytes: 200_000) + bookkeeping(blobBytes: 150_000))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(AppState.claudeTranscriptTurn(atPath: url.path), .ended)
    }

    /// A message longer than one piece (a tool result with an image) is
    /// joined up before it is read.
    func testAMessageLongerThanAPieceIsRead() throws {
        let url = try write([assistant(stop: "end_turn"),
                             user([["type": "text", "text": "[Request interrupted by user]"],
                                   ["type": "text", "text": String(repeating: "图", count: 100_000)]])])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(AppState.claudeTranscriptTurn(atPath: url.path), .ended)
    }

    /// No message within the budget: the turn counts as open, so it waits
    /// for the 30-minute ceiling instead of the five-minute rule.
    func testASpentBudgetReadsOpen() throws {
        let data = try tail([assistant(stop: "end_turn")] + bookkeeping(blobBytes: 1_000_000))
        let turn = AppState.claudeTranscriptTurn(size: UInt64(data.count), budget: 256 * 1024) { offset, length in
            data.subdata(in: Int(offset)..<(Int(offset) + length))
        }
        XCTAssertEqual(turn, .open)
        XCTAssertEqual(AppState.claudeTranscriptTurn(size: UInt64(data.count), budget: 4 << 20) { offset, length in
            data.subdata(in: Int(offset)..<(Int(offset) + length))
        }, .ended)
    }

    func testBookkeepingIsToldFromItsFirstBytes() {
        XCTAssertTrue(AppState.isClaudeBookkeepingLine(Data(#"{"type":"api-request-blob","hash":"h"}"#.utf8)[...]))
        XCTAssertTrue(AppState.isClaudeBookkeepingLine(Data(#"{"type":"custom-title","customTitle":"t"}"#.utf8)[...]))
        XCTAssertFalse(AppState.isClaudeBookkeepingLine(Data(#"{"type":"user","message":{}}"#.utf8)[...]))
        XCTAssertFalse(AppState.isClaudeBookkeepingLine(Data(#"{"type":"assistant","message":{}}"#.utf8)[...]))
        XCTAssertFalse(AppState.isClaudeBookkeepingLine(Data(#"{"parentUuid":null,"type":"user"}"#.utf8)[...]))
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
