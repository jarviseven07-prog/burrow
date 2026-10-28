import XCTest
@testable import CodeIsland

@MainActor
final class MascotAnimationGateTests: XCTestCase {
    func testShouldAnimateOnlyWhenVisibleAndAwake() {
        XCTAssertTrue(MascotAnimationGate.shouldAnimate(isVisible: true, isAwake: true))
        XCTAssertFalse(MascotAnimationGate.shouldAnimate(isVisible: false, isAwake: true))
        XCTAssertFalse(MascotAnimationGate.shouldAnimate(isVisible: true, isAwake: false))
        XCTAssertFalse(MascotAnimationGate.shouldAnimate(isVisible: false, isAwake: false))
    }

    func testHidingPanelStopsAnimationsWithoutBumpingEpoch() {
        let gate = MascotAnimationGate.shared
        gate.setPanelVisible(true)
        let baseEpoch = gate.epoch

        gate.setPanelVisible(false)
        XCTAssertFalse(gate.animationsActive)
        // Hiding must not re-anchor — only re-showing/waking does.
        XCTAssertEqual(gate.epoch, baseEpoch)
    }

    func testReShowingPanelBumpsEpochToReAnchorSchedules() {
        let gate = MascotAnimationGate.shared
        gate.setPanelVisible(false)
        let hiddenEpoch = gate.epoch

        gate.setPanelVisible(true)
        XCTAssertTrue(gate.animationsActive)
        XCTAssertEqual(gate.epoch, hiddenEpoch + 1)
    }

    func testRepeatedSameVisibilityIsIdempotent() {
        let gate = MascotAnimationGate.shared
        gate.setPanelVisible(true)
        let epoch = gate.epoch
        gate.setPanelVisible(true)
        XCTAssertEqual(gate.epoch, epoch)
    }

    /// #299 — a live TimelineView keeps SwiftUI's update machinery on a display
    /// link and re-runs the panel's whole layout pass every cycle, which is the
    /// bulk of the idle CPU baseline. A collapsed island with nothing running
    /// holds a static frame instead.
    func testSettledIslandStopsAnimationsEvenWhileVisibleAndAwake() {
        XCTAssertFalse(
            MascotAnimationGate.shouldAnimate(isVisible: true, isAwake: true, isIdleSettled: true)
        )
        XCTAssertTrue(
            MascotAnimationGate.shouldAnimate(isVisible: true, isAwake: true, isIdleSettled: false)
        )
    }

    func testLeavingTheSettledStateReAnchorsSchedules() {
        let gate = MascotAnimationGate.shared
        gate.setPanelVisible(true)
        gate.setIdleSettled(true)
        XCTAssertFalse(gate.animationsActive)
        let settledEpoch = gate.epoch

        gate.setIdleSettled(false)
        XCTAssertTrue(gate.animationsActive)
        XCTAssertEqual(
            gate.epoch,
            settledEpoch + 1,
            "resuming must re-anchor, or SwiftUI replays every tick missed while settled"
        )
    }

    func testReduceMotionHoldsTheMascotsStill() {
        XCTAssertFalse(MascotAnimationGate.shouldAnimate(isVisible: true, isAwake: true, reduceMotion: true))
        let gate = MascotAnimationGate.shared
        gate.setPanelVisible(true)
        gate.setIdleSettled(false)
        defer { gate.setReduceMotion(false) }
        gate.setReduceMotion(true)
        XCTAssertFalse(gate.animationsActive)
        let stillEpoch = gate.epoch
        gate.setReduceMotion(false)
        XCTAssertTrue(gate.animationsActive)
        XCTAssertEqual(gate.epoch, stillEpoch + 1, "resuming must re-anchor the schedules")
    }

    func testSettlingDoesNotReAnchor() {
        let gate = MascotAnimationGate.shared
        gate.setIdleSettled(false)
        let epoch = gate.epoch
        gate.setIdleSettled(true)
        XCTAssertEqual(gate.epoch, epoch)
        gate.setIdleSettled(false)
    }

    // A settled pet is asleep, not frozen: it breathes on the slow clock.
    func testSettledPetsBreatheOnTheSleepClock() {
        XCTAssertTrue(MascotAnimationGate.shouldBreathe(isVisible: true, isAwake: true, isIdleSettled: true, reduceMotion: false))
        XCTAssertFalse(MascotAnimationGate.shouldBreathe(isVisible: true, isAwake: true, isIdleSettled: false, reduceMotion: false),
                       "the live timeline covers an unsettled island")
        XCTAssertFalse(MascotAnimationGate.shouldBreathe(isVisible: false, isAwake: true, isIdleSettled: true, reduceMotion: false))
        XCTAssertFalse(MascotAnimationGate.shouldBreathe(isVisible: true, isAwake: false, isIdleSettled: true, reduceMotion: false))
        XCTAssertFalse(MascotAnimationGate.shouldBreathe(isVisible: true, isAwake: true, isIdleSettled: true, reduceMotion: true))

        let gate = MascotAnimationGate.shared
        let clock = MascotSleepClock.shared
        gate.setPanelVisible(true)
        gate.setIdleSettled(true)
        XCTAssertNotNil(clock.time, "settling starts the sleep clock")
        gate.setIdleSettled(false)
        XCTAssertNil(clock.time, "waking stops it")
    }
}
