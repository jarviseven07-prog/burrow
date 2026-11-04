import XCTest
@testable import CodeIsland

/// Health check 2026-11-04 #14: on a restart, a conversation whose last
/// hook was over three minutes ago stayed out of the den before anyone
/// asked whether it was still working — so one running a five-minute test
/// came back only when the test ended.
final class RestoreMidTurnTests: XCTestCase {
    private func transcript(_ lines: [[String: Any]]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString).jsonl")
        let body = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (body.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func assistant(stop: String, tool: String? = nil, id: String = "t1") -> [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text": "…"]]
        if let tool { content.append(["type": "tool_use", "id": id, "name": tool, "input": [:]]) }
        return ["type": "assistant", "message": ["role": "assistant", "stop_reason": stop, "content": content]]
    }

    private func result(for id: String) -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]]]
    }

    private var toolResult: [String: Any] { result(for: "t1") }

    func testALongToolCallComesBackRunningIt() throws {
        let url = try transcript([assistant(stop: "tool_use", tool: "Bash"), ["type": "last-prompt"]])
        defer { try? FileManager.default.removeItem(at: url) }
        let fourMinutesAgo = Date().addingTimeInterval(-4 * 60)
        XCTAssertTrue(AppState.isStaleIdleSession(lastActivity: fourMinutesAgo), "what kept it out")
        XCTAssertEqual(AppState.restoredClaudeTurn(source: "claude", processAlive: true,
                                                   lastActivity: fourMinutesAgo, transcriptPath: url.path), .tool("Bash"))
    }

    /// A running tool with a live process is never timed out (AGENTS.md),
    /// so even a 40-minute test comes back (review of #14).
    func testAToolRunningPastTheCeilingStillComesBack() throws {
        let url = try transcript([assistant(stop: "tool_use", tool: "Bash")])
        defer { try? FileManager.default.removeItem(at: url) }
        let longAgo = Date().addingTimeInterval(-AppState.claudeSilentTurnCeiling - 10 * 60)
        XCTAssertEqual(AppState.restoredClaudeTurn(source: "claude", processAlive: true,
                                                   lastActivity: longAgo, transcriptPath: url.path), .tool("Bash"))
    }

    /// Parallel calls are one line each, answered as each finishes: with one
    /// answered and a 40-minute test still going, it comes back running the
    /// test (review of #14).
    func testOneOfTwoParallelCallsStillRunning() throws {
        let prompt: [String: Any] = ["type": "user", "message": ["role": "user", "content": "跑一下测试"]]
        let url = try transcript([prompt, assistant(stop: "tool_use", tool: "Read", id: "a"),
                                  assistant(stop: "tool_use", tool: "Bash", id: "b"), result(for: "a")])
        let both = try transcript([prompt, assistant(stop: "tool_use", tool: "Read", id: "a"),
                                   assistant(stop: "tool_use", tool: "Bash", id: "b"), result(for: "b"), result(for: "a")])
        defer { [url, both].forEach { try? FileManager.default.removeItem(at: $0) } }
        let longAgo = Date().addingTimeInterval(-AppState.claudeSilentTurnCeiling - 10 * 60)
        XCTAssertEqual(AppState.restoredClaudeTurn(source: "claude", processAlive: true,
                                                   lastActivity: longAgo, transcriptPath: url.path), .tool("Bash"))
        XCTAssertNil(AppState.claudePendingTool(atPath: both.path), "both answered: thinking")
        XCTAssertEqual(AppState.restoredClaudeTurn(source: "claude", processAlive: true,
                                                   lastActivity: Date().addingTimeInterval(-4 * 60),
                                                   transcriptPath: both.path), .thinking)
    }

    /// A call from an earlier turn is not this turn's.
    func testTheSearchStopsAtTheTurnsPrompt() throws {
        let prompt: [String: Any] = ["type": "user", "message": ["role": "user", "content": "下一个"]]
        let url = try transcript([assistant(stop: "tool_use", tool: "Bash", id: "old"), prompt])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(AppState.claudePendingTool(atPath: url.path))
    }

    /// Thinking after a tool's result: open, within the silent-turn ceiling.
    func testThinkingComesBackWithinTheCeiling() throws {
        let url = try transcript([assistant(stop: "tool_use", tool: "Read"), toolResult])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(AppState.restoredClaudeTurn(source: "claude", processAlive: true,
                                                   lastActivity: Date().addingTimeInterval(-4 * 60),
                                                   transcriptPath: url.path), .thinking)
        XCTAssertNil(AppState.restoredClaudeTurn(source: "claude", processAlive: true,
                                                 lastActivity: Date().addingTimeInterval(-AppState.claudeSilentTurnCeiling - 60),
                                                 transcriptPath: url.path), "past the ceiling the sweep would settle it at once")
    }

    func testOnlyALiveOpenClaudeTurn() throws {
        let open = try transcript([assistant(stop: "tool_use", tool: "Bash")])
        let ended = try transcript([assistant(stop: "end_turn")])
        defer { [open, ended].forEach { try? FileManager.default.removeItem(at: $0) } }
        let recent = Date().addingTimeInterval(-4 * 60)
        XCTAssertNil(AppState.restoredClaudeTurn(source: "claude", processAlive: false, lastActivity: recent, transcriptPath: open.path))
        XCTAssertNil(AppState.restoredClaudeTurn(source: "claude", processAlive: true, lastActivity: recent, transcriptPath: ended.path))
        XCTAssertNil(AppState.restoredClaudeTurn(source: "codex", processAlive: true, lastActivity: recent, transcriptPath: open.path))
        XCTAssertNil(AppState.restoredClaudeTurn(source: "claude", processAlive: true, lastActivity: recent, transcriptPath: nil))
    }
}
