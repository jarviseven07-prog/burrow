import AppKit
import SwiftUI
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The den's status words and its needs-you-first order.
@MainActor
final class SessionListOrderingTests: XCTestCase {

    // MARK: - Status words

    func testEveryStatusHasItsOwnWord() {
        XCTAssertEqual(SessionCardStatus(session(.waitingApproval)), .needsYou)
        XCTAssertEqual(SessionCardStatus(session(.waitingQuestion)), .needsYou)
        XCTAssertEqual(SessionCardStatus(session(.running)), .working)
        XCTAssertEqual(SessionCardStatus(session(.processing)), .thinking)
        XCTAssertEqual(SessionCardStatus(session(.idle)), .idle, "nothing has happened yet")
        XCTAssertEqual(SessionCardStatus(session(.idle, prompt: "Fix it")), .done)

        var stopped = session(.idle, prompt: "Fix it")
        stopped.interrupted = true
        XCTAssertEqual(SessionCardStatus(stopped), .stopped)

        var failed = stopped
        failed.lastTurnFailed = true
        XCTAssertEqual(SessionCardStatus(failed), .error, "a failed turn outranks the interrupt")

        failed.status = .running
        XCTAssertEqual(SessionCardStatus(failed), .working, "the flags only describe an idle session")
    }

    func testStatusWordsAreSpelledOutInEveryLanguage() {
        let saved = L10n.shared.language
        defer { L10n.shared.language = saved }
        for language in ["en", "zh"] {
            L10n.shared.language = language
            let words = SessionCardStatus.allCases.map(\.label)
            XCTAssertEqual(Set(words).count, words.count, "\(language): two statuses share a word")
            for (status, word) in zip(SessionCardStatus.allCases, words) {
                XCTAssertNotEqual(word, status.labelKey, "\(language): \(status) has no word")
            }
        }
    }

    func testStatusIsNeverHueAlone() {
        // Working and thinking share a colour; their words tell them apart.
        XCTAssertNotEqual(SessionCardStatus.working.labelKey, SessionCardStatus.thinking.labelKey)
        XCTAssertEqual(SessionCardStatus.needsYou.tier, 0)
        XCTAssertEqual(SessionCardStatus.working.tier, 1)
        XCTAssertEqual(SessionCardStatus.thinking.tier, 1)
        for status in [SessionCardStatus.done, .idle, .stopped, .error] {
            XCTAssertEqual(status.tier, 2, "\(status)")
        }
    }

    // MARK: - Ordering

    func testNeedsYouFirstThenWorkingThenTheRestByRecentActivity() {
        let now = Date()
        // The request queued first is the older one and sorts last by name,
        // so only the queue rank can put it on top.
        let sessions: [String: SessionSnapshot] = [
            "a-idle-old": session(.idle, prompt: "p", activity: now.addingTimeInterval(-600)),
            "b-running": session(.running, started: now.addingTimeInterval(-300)),
            "c-question": session(.waitingQuestion, activity: now.addingTimeInterval(-5)),
            "d-idle-new": session(.idle, prompt: "p", activity: now.addingTimeInterval(-10)),
            "e-thinking": session(.processing, started: now.addingTimeInterval(-60)),
            "z-approval": session(.waitingApproval, activity: now.addingTimeInterval(-500)),
            "g-stopped": stoppedSession(activity: now.addingTimeInterval(-100)),
        ]
        let order = SessionListOrdering.order(sessions, requestRank: ["z-approval": 0, "c-question": 1])
        XCTAssertEqual(order, [
            "z-approval", "c-question",      // needs you, in queue order
            "e-thinking", "b-running",       // working, newest session first
            "d-idle-new", "g-stopped", "a-idle-old", // the rest, most recent activity first
        ])
        // Without a queue position, needs-you sessions go by recent activity.
        XCTAssertEqual(Array(SessionListOrdering.order(sessions).prefix(2)), ["c-question", "z-approval"])
    }

    func testApprovalsRankBeforeQuestionsInTheQueue() {
        let rank = SessionListOrdering.requestRank(
            permissionSessionIds: ["s2", "s1", "s2"],
            questionSessionIds: ["s3", "s1"]
        )
        XCTAssertEqual(rank, ["s2": 0, "s1": 1, "s3": 3])
    }

    func testAWorkingSessionsActivityDoesNotReshuffleTheList() {
        let now = Date()
        var sessions: [String: SessionSnapshot] = [
            "old": session(.running, started: now.addingTimeInterval(-900)),
            "new": session(.running, started: now.addingTimeInterval(-60)),
        ]
        let before = SessionListOrdering.order(sessions)
        sessions["old"]?.lastActivity = now.addingTimeInterval(5)
        XCTAssertEqual(SessionListOrdering.order(sessions), before, "every tool call would move the cards")
        XCTAssertEqual(before, ["new", "old"])
    }

    func testOrderIsStableForEqualKeys() {
        let date = Date()
        let sessions = Dictionary(uniqueKeysWithValues: ["c", "a", "b"].map {
            ($0, session(.idle, prompt: "p", activity: date, started: date))
        })
        XCTAssertEqual(SessionListOrdering.order(sessions), ["a", "b", "c"])
    }

    func testAppStateOrdersByItsRequestQueues() async throws {
        // "zeta" asked first but is older and sorts last by name: only the
        // queue can put it on top.
        let state = AppState()
        let now = Date()
        state.sessions = [
            "idle": session(.idle, prompt: "p", activity: now),
            "alpha": session(.waitingApproval, activity: now.addingTimeInterval(-5)),
            "zeta": session(.waitingApproval, activity: now.addingTimeInterval(-300)),
        ]
        let releaseFirst = await DemoRequests.enqueuePermission(state, event: try DemoRequests.hookEvent([
            "hook_event_name": "PermissionRequest", "session_id": "zeta", "tool_name": "Bash",
            "tool_input": ["command": "ls"],
        ]))
        let releaseSecond = await DemoRequests.enqueuePermission(state, event: try DemoRequests.hookEvent([
            "hook_event_name": "PermissionRequest", "session_id": "alpha", "tool_name": "Bash",
            "tool_input": ["command": "pwd"],
        ]))
        defer { releaseSecond(); releaseFirst() }
        XCTAssertEqual(state.sessionListOrder(), ["zeta", "alpha", "idle"],
                       "the request the inline buttons can answer comes first")
    }


    // MARK: - ERROR after a failed turn

    func testAFailedTurnReadsErrorUntilTheNextPrompt() throws {
        let state = AppState()
        state.handleEvent(try hook(["hook_event_name": "UserPromptSubmit", "session_id": "err", "prompt": "go"]))
        state.handleEvent(try hook(["hook_event_name": "StopFailure", "session_id": "err", "error_type": "rate_limit"]))
        let failed = try XCTUnwrap(state.sessions["err"])
        XCTAssertTrue(failed.lastTurnFailed)
        XCTAssertEqual(SessionCardStatus(failed), .error)

        state.handleEvent(try hook(["hook_event_name": "UserPromptSubmit", "session_id": "err", "prompt": "again"]))
        XCTAssertEqual(state.sessions["err"]?.lastTurnFailed, false)
        XCTAssertEqual(state.sessions["err"].map(SessionCardStatus.init), .thinking)

        state.handleEvent(try hook(["hook_event_name": "Stop", "session_id": "err"]))
        XCTAssertEqual(state.sessions["err"].map(SessionCardStatus.init), .done)
    }

    // MARK: - Fixtures

    private func session(
        _ status: AgentStatus,
        prompt: String? = nil,
        activity: Date = Date(),
        started: Date = Date()
    ) -> SessionSnapshot {
        var s = SessionSnapshot(startTime: started)
        s.source = "claude"
        s.status = status
        s.lastUserPrompt = prompt
        s.lastActivity = activity
        return s
    }

    private func stoppedSession(activity: Date) -> SessionSnapshot {
        var s = session(.idle, prompt: "p", activity: activity)
        s.interrupted = true
        return s
    }

    private func hook(_ payload: [String: Any]) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: payload)))
    }
}

/// Compact rows on the real panel: eight sessions in the window a 14"
/// MacBook gives the panel, without scrolling, at the default and the
/// largest text size.
