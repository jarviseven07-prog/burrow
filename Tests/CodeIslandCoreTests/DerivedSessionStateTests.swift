import XCTest
@testable import CodeIslandCore

final class DerivedSessionStateTests: XCTestCase {
    func testAllIdleSessionsUseMostRecentlyActiveSource() {
        var older = SessionSnapshot()
        older.source = "claude"
        older.status = .idle
        older.lastActivity = Date(timeIntervalSince1970: 100)

        var newer = SessionSnapshot()
        newer.source = "codex"
        newer.status = .idle
        newer.lastActivity = Date(timeIntervalSince1970: 200)

        let summary = deriveSessionSummary(from: [
            "older": older,
            "newer": newer,
        ])

        XCTAssertEqual(summary.primarySource, "codex")
        XCTAssertEqual(summary.activeSessionCount, 0)
        XCTAssertEqual(summary.totalSessionCount, 2)
    }

    func testCLIProcessResolverFallsBackToImmediateParentWhenNoMatchFound() {
        let pid = CLIProcessResolver.resolvedTrackedPID(
            immediateParentPID: 100,
            source: "claude",
            ancestry: [
                (pid: 100, executablePath: "/bin/sh"),
                (pid: 88, executablePath: "/usr/bin/login"),
            ]
        )

        XCTAssertEqual(pid, 100)
    }

    // MARK: - Source inference (issue #95)

    func testInferSourceFindsOpencodeInAncestryWhenSourceTagMissing() {
        // omo plugin triggers Claude hooks, but the real CLI up the ancestry is OpenCode.
        let source = CLIProcessResolver.inferSource(ancestry: [
            (pid: 200, executablePath: "/bin/sh"),
            (pid: 150, executablePath: "/usr/local/bin/node"),
            (pid: 100, executablePath: "/Applications/OpenCode.app/Contents/MacOS/OpenCode"),
        ])

        XCTAssertEqual(source, "opencode")
    }

    func testInferSourceReturnsNilWhenNoKnownBinaryInAncestry() {
        let source = CLIProcessResolver.inferSource(ancestry: [
            (pid: 200, executablePath: "/bin/sh"),
            (pid: 150, executablePath: "/usr/bin/login"),
            (pid: 100, executablePath: "/sbin/launchd"),
        ])

        XCTAssertNil(source)
    }

    func testInferSourceReturnsClosestMatchAlongAncestry() {
        // If multiple known CLIs appear, the nearest ancestor wins.
        let source = CLIProcessResolver.inferSource(ancestry: [
            (pid: 200, executablePath: "/usr/local/bin/codex"),
            (pid: 100, executablePath: "/Applications/Claude.app/Contents/MacOS/claude"),
        ])

        XCTAssertEqual(source, "codex")
    }

    func testExtractMetadataPrefersWorkspaceRootsOverHomeClaudeCwd() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let workspace = "/tmp/codeisland-workspace"
        var sessions: [String: SessionSnapshot] = ["s1": SessionSnapshot()]
        let event = try decode([
            "hook_event_name": "PreToolUse",
            "session_id": "s1",
            "_source": "claude",
            "cwd": "\(home)/.claude",
            "workspace_roots": [workspace],
        ])

        extractMetadata(into: &sessions, sessionId: "s1", event: event)

        XCTAssertEqual(sessions["s1"]?.cwd, workspace)
    }

    /// A Claude transcript path also contains a "projects" component
    /// (~/.claude/projects/<encoded>/…) — it must not hijack cwd. The home
    /// cwd itself is kept as a last resort so model lookup keeps working.
    func testExtractMetadataKeepsHomeCwdForClaudeTranscripts() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var sessions: [String: SessionSnapshot] = ["s1": SessionSnapshot()]
        let event = try decode([
            "hook_event_name": "PreToolUse",
            "session_id": "s1",
            "_source": "claude",
            "cwd": home,
            "transcript_path": "\(home)/.claude/projects/-Users-someone/abc123.jsonl",
        ])

        extractMetadata(into: &sessions, sessionId: "s1", event: event)

        XCTAssertEqual(sessions["s1"]?.cwd, home)
    }

    func testStopDoesNotDuplicateReplyAlreadyAppendedByTranscriptTailer() throws {
        // mcode's Stop carries last_assistant_message — the same reply the
        // transcript tailer appends when the assistant row lands. The Stop
        // path must not append it a second time (maxCount 3 means a dupe
        // crowds a real row off the card).
        var session = SessionSnapshot()
        session.source = "opencode"
        session.lastUserPrompt = "你是谁"
        session.recentMessages = [
            ChatMessage(isUser: true, text: "你是谁"),
            ChatMessage(isUser: false, text: "我是 MiniMax Code"),
        ]
        session.lastAssistantMessage = "我是 MiniMax Code"
        var sessions = ["mvs_dup": session]

        let event = try decode([
            "hook_event_name": "Stop",
            "session_id": "mvs_dup",
            "_source": "opencode",
            "last_assistant_message": "我是 MiniMax Code",
        ])
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 3)

        let assistantRows = sessions["mvs_dup"]?.recentMessages.filter { !$0.isUser }
        XCTAssertEqual(assistantRows?.count, 1, "Stop must not re-append the tailer's reply")
        XCTAssertEqual(sessions["mvs_dup"]?.status, .idle)
    }

    func testStopStillAppendsAReplyTheTailerHasNotSeen() throws {
        // A Stop whose reply text differs from what the tail last appended
        // (interrupted turn, tailer detached…) must still land on the card.
        var session = SessionSnapshot()
        session.source = "opencode"
        session.recentMessages = [ChatMessage(isUser: true, text: "你好")]
        var sessions = ["mvs_new": session]

        let event = try decode([
            "hook_event_name": "Stop",
            "session_id": "mvs_new",
            "_source": "opencode",
            "last_assistant_message": "你好！有什么我可以帮你的吗？",
        ])
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 3)

        let assistantRows = sessions["mvs_new"]?.recentMessages.filter { !$0.isUser }
        XCTAssertEqual(assistantRows?.count, 1)
        XCTAssertEqual(assistantRows?.first?.text, "你好！有什么我可以帮你的吗？")
    }

    func testStopAppendsARepeatedReplyToANewPrompt() throws {
        // Same answer twice ("Done.") to two prompts: the earlier reply is an
        // older row, not this turn's. The tail channel skips the repeat (its
        // lastAssistantMessage didn't change), so Stop is the only path that
        // can put the answer under the new prompt.
        var session = SessionSnapshot()
        session.source = "claude"
        session.recentMessages = [
            ChatMessage(isUser: true, text: "run the tests"),
            ChatMessage(isUser: false, text: "Done."),
            ChatMessage(isUser: true, text: "run them again"),
        ]
        session.lastAssistantMessage = "Done."
        var sessions = ["s-repeat": session]

        let event = try decode([
            "hook_event_name": "Stop",
            "session_id": "s-repeat",
            "last_assistant_message": "Done.",
        ])
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 3)

        XCTAssertEqual(sessions["s-repeat"]?.recentMessages.last?.isUser, false)
        XCTAssertEqual(sessions["s-repeat"]?.recentMessages.last?.text, "Done.")
    }

    private func decode(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("HookEvent should decode payload: \(payload)")
            throw NSError(domain: "DerivedSessionStateTests", code: 1)
        }
        return event
    }
}
