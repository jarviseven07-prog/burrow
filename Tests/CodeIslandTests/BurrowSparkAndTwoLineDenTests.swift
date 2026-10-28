import XCTest
import CodeIslandCore
@testable import CodeIsland

/// design/v20: a spark by a pet whose turn finished until you open the den,
/// and two lines per conversation in the den.
@MainActor
final class BurrowSparkAndTwoLineDenTests: XCTestCase {
    private func done() -> SessionSnapshot {
        var s = SessionSnapshot()
        s.status = .idle
        s.lastAssistantMessage = "做好了"
        return s
    }

    func testASparkStaysUntilTheDenHasBeenOpened() {
        let finished = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(BurrowSpark.isUnseen(done(), doneAt: finished, seenAt: .distantPast))
        XCTAssertTrue(BurrowSpark.isUnseen(done(), doneAt: finished, seenAt: finished.addingTimeInterval(-1)))
        XCTAssertFalse(BurrowSpark.isUnseen(done(), doneAt: finished, seenAt: finished.addingTimeInterval(1)))
        XCTAssertFalse(BurrowSpark.isUnseen(done(), doneAt: nil, seenAt: .distantPast),
                       "a conversation restored at launch brings no spark")
        var working = done()
        working.status = .running
        XCTAssertFalse(BurrowSpark.isUnseen(working, doneAt: finished, seenAt: .distantPast), "a new turn is under way")
        var failed = done()
        failed.lastTurnFailed = true
        XCTAssertFalse(BurrowSpark.isUnseen(failed, doneAt: finished, seenAt: .distantPast), "a failure has its ember")
    }

    func testOnlyATurnThatDidNotFailLeavesASpark() {
        let app = AppState()
        app.sessions["a"] = done()
        app.enqueueCompletion("a")
        XCTAssertNotNil(app.turnDoneAt["a"])
        app.enqueueCompletion("a", turnFailed: true)
        XCTAssertNil(app.turnDoneAt["a"])
    }

    /// The den lights what finished since the look before it was opened,
    /// while the notch's sparks go out with the opening.
    func testTheOpenDenRemembersTheLookBeforeIt() {
        let app = AppState()
        app.surface = .sessionList
        let first = app.denSeenAt
        XCTAssertEqual(app.denLookBefore, .distantPast)
        app.surface = .collapsed
        let closed = app.denSeenAt
        app.surface = .sessionList
        XCTAssertEqual(app.denLookBefore, closed)
        XCTAssertGreaterThanOrEqual(closed, first)
        app.surface = .sessionList
        XCTAssertEqual(app.denLookBefore, closed, "staying open is not another look")
    }

    func testAFreshRowWearsTheSpark() {
        XCTAssertEqual(BurrowRowSign.Kind(status: .done, sign: nil, fresh: true), .spark)
        XCTAssertEqual(BurrowRowSign.Kind(status: .done, sign: nil, fresh: false), .none)
        XCTAssertEqual(BurrowRowSign.Kind(status: .error, sign: nil, fresh: true), .ember)
    }

    func testTheSparkIsAPlusAroundItsCentre() {
        for twinkling in [true, false] {
            let rows = BurrowSpark.rows(twinkling: twinkling)
            XCTAssertEqual(rows.count, 3)
            XCTAssertTrue(rows.allSatisfy { $0.count == 3 })
            XCTAssertEqual(Array(rows[1])[1], "b", "the bright centre is always lit")
        }
    }

    /// A conversation is two lines now; one alone still fits beside its pet,
    /// so its block has no gap under the row.
    func testTwoLinesStillFitBesideOnePet() {
        XCTAssertLessThanOrEqual(BurrowDenMetrics.rowHeight, BurrowDenMetrics.petBlockHeight)
        XCTAssertGreaterThan(2 * BurrowDenMetrics.rowHeight, BurrowDenMetrics.petBlockHeight)
    }
}
