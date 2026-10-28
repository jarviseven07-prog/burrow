import XCTest
import CodeIslandCore
@testable import CodeIsland

/// A finished conversation stays in the den until the den has shown it, then
/// `seenIdleGraceMinutes` more. It used to go 3 minutes after it finished
/// (the inherited session timeout), while its spark still sent you to the den.
@MainActor
final class BurrowIdleUntilSeenTests: XCTestCase {
    func testAnUnseenConversationStaysHoweverLongItHasBeenIdle() {
        let finished = Date(timeIntervalSince1970: 1_000)
        let aDayLater = finished.addingTimeInterval(86_400)
        let grace = TimeInterval(AppState.seenIdleGraceMinutes * 60)
        XCTAssertFalse(AppState.isStaleIdleSession(lastActivity: finished, seenAt: nil, now: aDayLater))
        XCTAssertFalse(AppState.isStaleIdleSession(lastActivity: finished, seenAt: finished.addingTimeInterval(-1), now: aDayLater),
                       "a look before the turn finished is not a look at it")
        let seen = finished.addingTimeInterval(600)
        XCTAssertFalse(AppState.isStaleIdleSession(lastActivity: finished, seenAt: seen, now: seen.addingTimeInterval(grace - 1)))
        XCTAssertTrue(AppState.isStaleIdleSession(lastActivity: finished, seenAt: seen, now: seen.addingTimeInterval(grace)))
    }

    func testOpeningTheDenMarksTheFinishedConversationsSeen() {
        let app = AppState()
        var idle = SessionSnapshot()
        idle.status = .idle
        idle.lastActivity = Date().addingTimeInterval(-3_600)
        var working = idle
        working.status = .running
        app.sessions["done"] = idle
        app.sessions["busy"] = working

        app.surface = .sessionList
        let firstLook = app.idleSeenAt["done"]
        XCTAssertNotNil(firstLook)
        XCTAssertNil(app.idleSeenAt["busy"], "a conversation still working has nothing finished to see")
        app.surface = .collapsed
        XCTAssertEqual(app.idleSeenAt["done"], firstLook, "the grace counts from the first look, not the latest")
    }

    func testARestartBringsBackAFinishedConversationWhoseProcessStillRuns() {
        defer { SessionPersistence.clear() }
        var alive = SessionSnapshot()
        alive.source = "claude"
        alive.cliPid = getpid()
        alive.lastUserPrompt = "整理一下"
        alive.lastActivity = Date().addingTimeInterval(-2 * 3_600)
        var ended = alive
        ended.cliPid = nil
        SessionPersistence.save(["alive": alive, "ended": ended])

        let app = AppState()
        app.restoreSessions()

        XCTAssertNotNil(app.sessions["alive"])
        XCTAssertNil(app.sessions["ended"], "a conversation whose process has ended is not brought back after half an hour")
    }
}
