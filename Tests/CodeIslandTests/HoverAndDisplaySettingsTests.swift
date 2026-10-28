import XCTest
@testable import CodeIsland
import CodeIslandCore

final class HoverAndDisplaySettingsTests: XCTestCase {
    // MARK: - Hover expand delay

    func testDefaultHoverDelayIsUnchanged() {
        XCTAssertEqual(SettingsDefaults.hoverExpandDelay, 0.5)
        XCTAssertEqual(NotchHoverInteraction.expandDelay(forSetting: SettingsDefaults.hoverExpandDelay), 0.5)
    }

    func testHoverDelayIsClampedIntoTheOfferedRange() {
        XCTAssertEqual(NotchHoverInteraction.expandDelay(forSetting: 0.1), 0.1)
        XCTAssertEqual(NotchHoverInteraction.expandDelay(forSetting: 0.75), 0.75)
        XCTAssertEqual(NotchHoverInteraction.expandDelay(forSetting: 1.0), 1.0)
        // A hand-written or zeroed preference must never produce an instant or
        // negative timer.
        XCTAssertEqual(NotchHoverInteraction.expandDelay(forSetting: 0), 0.1)
        XCTAssertEqual(NotchHoverInteraction.expandDelay(forSetting: -3), 0.1)
        XCTAssertEqual(NotchHoverInteraction.expandDelay(forSetting: 12), 1.0)
    }

    func testNonFiniteHoverDelayFallsBackToTheDefault() {
        XCTAssertEqual(NotchHoverInteraction.expandDelay(forSetting: .nan), NotchHoverInteraction.expandDelay)
        XCTAssertEqual(NotchHoverInteraction.expandDelay(forSetting: .infinity), NotchHoverInteraction.expandDelay)
    }

    func testHoverDelayRangeMatchesTheRequestedBounds() {
        XCTAssertEqual(NotchHoverInteraction.expandDelayRange.lowerBound, 0.1)
        XCTAssertEqual(NotchHoverInteraction.expandDelayRange.upperBound, 1.0)
    }

    /// An approval or question card that opened while the hover delay was
    /// running must not be swapped out for the session list when it elapses.
    func testElapsedHoverDelayNeverReplacesAPendingCard() {
        XCTAssertFalse(NotchHoverInteraction.hoverExpansionMayReplace(.approvalCard(sessionId: "s")))
        XCTAssertFalse(NotchHoverInteraction.hoverExpansionMayReplace(.questionCard(sessionId: "s")))
        XCTAssertTrue(NotchHoverInteraction.hoverExpansionMayReplace(.collapsed))
        XCTAssertTrue(NotchHoverInteraction.hoverExpansionMayReplace(.sessionList))
        XCTAssertTrue(NotchHoverInteraction.hoverExpansionMayReplace(.completionCard(sessionId: "s")))
    }

    // MARK: - Content font size

    func testContentFontSizeGoesUpTo16pt() {
        XCTAssertEqual(ContentFontSize.choices.first, 10)
        XCTAssertEqual(ContentFontSize.choices.last, 16)
        XCTAssertEqual(ContentFontSize.choices, Array(10...16), "every step is selectable")
        XCTAssertTrue(ContentFontSize.choices.contains(SettingsDefaults.contentFontSize))
    }

    // MARK: - Completion card duration

    func testCompletionCardStaysTenSecondsByDefault() {
        XCTAssertEqual(SettingsDefaults.completionCardDuration, 10)
        XCTAssertEqual(CompletionCardDuration.seconds(forSetting: SettingsDefaults.completionCardDuration), 10)
    }

    func testCompletionCardDurationIsClampedIntoTheOfferedRange() {
        XCTAssertEqual(CompletionCardDuration.seconds(forSetting: 3), 3)
        XCTAssertEqual(CompletionCardDuration.seconds(forSetting: 25), 25)
        XCTAssertEqual(CompletionCardDuration.seconds(forSetting: 60), 60)
        // An unset (0), negative or huge preference never folds the card at
        // once or keeps it up for good.
        XCTAssertEqual(CompletionCardDuration.seconds(forSetting: 0), 3)
        XCTAssertEqual(CompletionCardDuration.seconds(forSetting: -1), 3)
        XCTAssertEqual(CompletionCardDuration.seconds(forSetting: 999), 60)
        XCTAssertEqual(CompletionCardDuration.seconds(forSetting: .nan), CompletionCardDuration.defaultSeconds)
    }

    @MainActor
    func testCompletionCardReadsTheSetting() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: SettingsKey.completionCardDuration)
        defer { defaults.set(previous, forKey: SettingsKey.completionCardDuration) }

        let appState = AppState()
        defaults.set(20.0, forKey: SettingsKey.completionCardDuration)
        XCTAssertEqual(appState.completionAutoCollapseDelay, 20)
        appState.completionAutoCollapseDelay = 0.05
        XCTAssertEqual(appState.completionAutoCollapseDelay, 0.05, "a test override wins over the setting")
    }
}
