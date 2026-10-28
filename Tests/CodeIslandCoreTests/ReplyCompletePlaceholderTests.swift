import XCTest
@testable import CodeIslandCore

final class ReplyCompletePlaceholderTests: XCTestCase {
    private func hookEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("HookEvent should decode payload: \(payload)")
            throw NSError(domain: "ReplyCompletePlaceholderTests", code: 1)
        }
        return event
    }


    // MARK: - Stop event

    func testStopEventUsesInjectedPlaceholderWhenNoMessageContent() throws {
        var session = SessionSnapshot()
        session.source = "opencode"
        session.addRecentMessage(ChatMessage(isUser: true, text: "do the thing"))
        var sessions = ["cb-session": session]

        let event = try hookEvent([
            "hook_event_name": "Stop",
            "session_id": "cb-session",
            "_source": "opencode",
        ])
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 20,
                        replyCompletePlaceholder: "返信完了")

        let last = sessions["cb-session"]?.recentMessages.last
        XCTAssertEqual(last?.isUser, false)
        XCTAssertEqual(last?.text, "返信完了")
    }

    func testStopEventUsesMessageContentWhenPresent() throws {
        var session = SessionSnapshot()
        session.source = "opencode"
        session.addRecentMessage(ChatMessage(isUser: true, text: "do the thing"))
        var sessions = ["cb-session": session]

        let event = try hookEvent([
            "hook_event_name": "Stop",
            "session_id": "cb-session",
            "_source": "opencode",
            "message": "Task finished",
        ])
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 20,
                        replyCompletePlaceholder: "Reply complete")

        let last = sessions["cb-session"]?.recentMessages.last
        XCTAssertEqual(last?.text, "Task finished")
    }

    // MARK: - Default value

    func testDefaultPlaceholderIsEnglishWithoutBrackets() throws {
        var session = SessionSnapshot()
        session.source = "opencode"
        session.addRecentMessage(ChatMessage(isUser: true, text: "do the thing"))
        var sessions = ["cb-session": session]

        let event = try hookEvent([
            "hook_event_name": "Stop",
            "session_id": "cb-session",
            "_source": "opencode",
        ])
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 20)

        let last = sessions["cb-session"]?.recentMessages.last
        XCTAssertEqual(last?.text, "Reply complete")
        XCTAssertFalse(last?.text.hasPrefix("[") ?? true, "Default placeholder must not start with '['")
    }

    // MARK: - Placeholder skipped when prior assistant message exists

    func testPlaceholderIsSkippedWhenLastAssistantMessageAlreadySet() throws {
        var session = SessionSnapshot()
        session.source = "opencode"
        session.lastAssistantMessage = "previous reply"
        session.addRecentMessage(ChatMessage(isUser: true, text: "follow-up"))
        var sessions = ["cb-session": session]

        let event = try hookEvent([
            "hook_event_name": "Stop",
            "session_id": "cb-session",
            "_source": "opencode",
        ])
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 20,
                        replyCompletePlaceholder: "Reply complete")

        let messages = sessions["cb-session"]?.recentMessages ?? []
        XCTAssertFalse(messages.contains(where: { $0.text == "Reply complete" }),
                       "Placeholder must not be added when lastAssistantMessage is already set")
    }
}
