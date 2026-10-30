import XCTest
import CodeIslandCore
@testable import CodeIsland

/// A finished conversation leaves the den `finishedIdleMinutes` after its last
/// turn, seen or not (Jarvis, 2026-10-29). From 10-28 it had stayed until the
/// den had shown it, so rows sat there for tens of minutes.
@MainActor
final class BurrowFinishedIdleTests: XCTestCase {
    func testAFinishedConversationGoesThreeMinutesAfterItsLastTurn() {
        let finished = Date(timeIntervalSince1970: 1_000)
        let grace = TimeInterval(AppState.finishedIdleMinutes * 60)
        XCTAssertEqual(AppState.finishedIdleMinutes, 3)
        XCTAssertFalse(AppState.isStaleIdleSession(lastActivity: finished, now: finished.addingTimeInterval(grace - 1)))
        XCTAssertTrue(AppState.isStaleIdleSession(lastActivity: finished, now: finished.addingTimeInterval(grace)))
    }

    func testARestartBringsBackOnlyConversationsThatFinishedWithinThreeMinutes() {
        defer { SessionPersistence.clear() }
        var recent = SessionSnapshot()
        recent.source = "claude"
        recent.cliPid = getpid()
        recent.lastUserPrompt = "整理一下"
        recent.lastActivity = Date().addingTimeInterval(-60)
        var old = recent
        old.lastActivity = Date().addingTimeInterval(-5 * 60)
        SessionPersistence.save(["recent": recent, "old": old])

        let app = AppState()
        app.restoreSessions()

        XCTAssertNotNil(app.sessions["recent"])
        XCTAssertNil(app.sessions["old"], "finished five minutes ago: the sweep would take it at once, so it stays out")
    }
    func testAScanDoesNotBringBackAConversationThatFinishedOverThreeMinutesAgo() {
        let app = AppState()
        func found(_ id: String, minutesAgo: Double) -> AppState.DiscoveredSession {
            AppState.DiscoveredSession(sessionId: id, cwd: "/tmp/\(id)", tty: nil, model: nil, pid: nil,
                                       modifiedAt: Date().addingTimeInterval(-minutesAgo * 60), recentMessages: [])
        }
        app.integrateDiscovered([found("fresh", minutesAgo: 1), found("taken", minutesAgo: 4)])
        XCTAssertNotNil(app.sessions["fresh"])
        XCTAssertNil(app.sessions["taken"], "Claude's scan finds transcripts written in the last five minutes; the sweep took this one")
    }
}
