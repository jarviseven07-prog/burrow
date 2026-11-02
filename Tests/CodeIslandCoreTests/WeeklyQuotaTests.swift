import XCTest
@testable import CodeIslandCore

/// design/v24 D: the weekly-quota health bars under the pets.
final class WeeklyQuotaTests: XCTestCase {
    func testHealthBands() {
        XCTAssertEqual(WeeklyQuota.health(93), .good)
        XCTAssertEqual(WeeklyQuota.health(30), .good)
        XCTAssertEqual(WeeklyQuota.health(29), .short)
        XCTAssertEqual(WeeklyQuota.health(15), .short)
        XCTAssertEqual(WeeklyQuota.health(14.9), .critical)
    }

    func testLitCellsKeepOneWhileAnythingIsLeft() {
        XCTAssertEqual(WeeklyQuota.litCells(100, of: 18), 18)
        XCTAssertEqual(WeeklyQuota.litCells(52, of: 18), 9)
        XCTAssertEqual(WeeklyQuota.litCells(1, of: 18), 1)
        XCTAssertEqual(WeeklyQuota.litCells(0, of: 18), 0)
    }

    func testClaudeReadsTheLatestSampleOfThisWeek() {
        let now = Date(timeIntervalSince1970: 1_793_600_000)
        let json = #"{"version":2,"samples":[{"t":1793580253021,"u":{"fh":1,"sd":4}},{"t":1793594957755,"u":{"fh":1,"sd":7}}]}"#
        XCTAssertEqual(WeeklyQuota.claudeRemaining(historyJSON: Data(json.utf8), now: now), 93)
        let weekLater = now.addingTimeInterval(8 * 24 * 3600)
        XCTAssertNil(WeeklyQuota.claudeRemaining(historyJSON: Data(json.utf8), now: weekLater))
    }

    func testCodexUsesTheWeeklyWindow() {
        let result: [String: Any] = ["rateLimits": [
            "primary": ["usedPercent": 42, "windowDurationMins": 300],
            "secondary": ["usedPercent": 48, "windowDurationMins": 10080],
        ]]
        XCTAssertEqual(WeeklyQuota.codexRemaining(rateLimitsResult: result), 52)
        XCTAssertNil(WeeklyQuota.codexRemaining(rateLimitsResult: [:]))
    }

    /// The 11-02 `/usage` reply: the tightest weekly line, never a 5-hour one.
    func testAntigravityTakesTheTightestWeeklyGroup() {
        let text = """
        - **Gemini Models**
          - **Weekly Limit Remaining:** 92% remaining (resets Nov 03, 2026, 09:24 UTC)
          - **Five Hour Limit Remaining:** 3% remaining (resets Nov 02, 2026, 14:12 UTC)
        - **Claude and GPT models**
          - **Weekly Limit Remaining:** 17% remaining (resets Nov 03, 2026, 12:03 UTC)
        - **Gemini 4 Argon**
          - **Gemini 4 Argon Weekly Limit:** 22% remaining (resets Nov 03, 2026, 09:28 UTC)
        """
        XCTAssertEqual(WeeklyQuota.antigravityRemaining(usageText: text), 17)
        XCTAssertNil(WeeklyQuota.antigravityRemaining(usageText: "data not available yet"))
    }

    func testOpenCodeTakesTheTighterBalance() {
        let ds = Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"76.75"}]}"#.utf8)
        let or = Data(#"{"data":{"total_credits":80,"total_usage":63.03}}"#.utf8)
        XCTAssertEqual(WeeklyQuota.deepSeekBalance(ds), 76.75)
        XCTAssertEqual(WeeklyQuota.openRouterBalance(or)!, 16.97, accuracy: 0.001)
        XCTAssertEqual(WeeklyQuota.openCodeRemaining(deepSeek: 76.75, openRouter: 16.97)!, 76.75, accuracy: 0.001)
        XCTAssertEqual(WeeklyQuota.openCodeRemaining(deepSeek: nil, openRouter: 3)!, 15, accuracy: 0.001)
        XCTAssertNil(WeeklyQuota.openCodeRemaining(deepSeek: nil, openRouter: nil))
        XCTAssertEqual(WeeklyQuota.balanceLabel(deepSeek: 71.27, openRouter: 16.96), "¥71 · $17")
        XCTAssertEqual(WeeklyQuota.balanceLabel(deepSeek: nil, openRouter: 3.2), "$3")
        XCTAssertNil(WeeklyQuota.balanceLabel(deepSeek: nil, openRouter: nil))
    }
}
