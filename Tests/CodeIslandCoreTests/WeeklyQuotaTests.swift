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

    /// Health check 2026-11-04 #18: with only the 5-hour window in the reply,
    /// the bar went red on "3%". Only a week-long window counts; a reply with
    /// no lengths at all still means `secondary` is the weekly one.
    func testCodexNeverShowsTheFiveHourWindow() {
        let fiveHourOnly: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 97, "windowDurationMins": 300]]]
        XCTAssertNil(WeeklyQuota.codexRemaining(rateLimitsResult: fiveHourOnly))
        let swapped: [String: Any] = ["rateLimits": [
            "primary": ["usedPercent": 20, "windowDurationMins": 10080],
            "secondary": ["usedPercent": 97, "windowDurationMins": 300],
        ]]
        XCTAssertEqual(WeeklyQuota.codexRemaining(rateLimitsResult: swapped), 80)
        let noLengths: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 97], "secondary": ["usedPercent": 40]]]
        XCTAssertEqual(WeeklyQuota.codexRemaining(rateLimitsResult: noLengths), 60)
        let primaryOnlyNoLength: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 97]]]
        XCTAssertNil(WeeklyQuota.codexRemaining(rateLimitsResult: primaryOnlyNoLength))
    }

    /// Health check #21: Claude Desktop closed across the weekly reset kept
    /// last week's number. The samples show when the week last started over
    /// (usage falling back); a week after that, a sample from before it is
    /// last week's, and there is no bar until Desktop writes a new one.
    func testClaudeDropsASampleFromBeforeTheWeeklyReset() {
        // 87% at 21:47, then 0% at 22:23 the same evening: the reset.
        let beforeReset = 1_793_537_220_000.0, afterReset = 1_793_539_380_000.0
        let day = 24 * 3600 * 1000.0
        let json = """
        {"version":2,"samples":[{"t":\(Int(beforeReset - day)),"u":{"sd":80}},{"t":\(Int(beforeReset)),"u":{"sd":87}},\
        {"t":\(Int(afterReset)),"u":{"sd":0}},{"t":\(Int(afterReset + 5 * day)),"u":{"sd":64}}]}
        """
        let data = Data(json.utf8)
        let sixDaysOn = Date(timeIntervalSince1970: (afterReset + 6 * day) / 1000)
        XCTAssertEqual(WeeklyQuota.claudeRemaining(historyJSON: data, now: sixDaysOn), 36, "still this week")
        let pastTheNextReset = Date(timeIntervalSince1970: (beforeReset + 7 * day) / 1000 + 60)
        XCTAssertNil(WeeklyQuota.claudeRemaining(historyJSON: data, now: pastTheNextReset), "last week's number")

        // A sample written after that reset is this week's again.
        let fresh = json.replacingOccurrences(of: "]}", with: ",{\"t\":\(Int(beforeReset + 7 * day + 120_000)),\"u\":{\"sd\":2}}]}")
        XCTAssertEqual(WeeklyQuota.claudeRemaining(historyJSON: Data(fresh.utf8),
                                                   now: pastTheNextReset.addingTimeInterval(3600)), 98)
    }

    /// The weekly reset keeps its time of the week; a one-off early reset
    /// (Jarvis's history has one on a Monday) does not move it.
    func testAnEarlyResetDoesNotMoveTheWeeklyOne() {
        let week = 7 * 24 * 3600.0, saturday = 1_792_000_000.0
        let samples: [(t: TimeInterval, used: Double)] = [
            (saturday - 600, 80), (saturday + 1800, 0),                       // a Saturday reset
            (saturday + 2 * 86400, 50), (saturday + 2 * 86400 + 900, 1),      // early, on Monday
            (saturday + week - 3600, 70), (saturday + week + 600, 2),         // next Saturday
            (saturday + week + 86400, 9),
        ]
        let window = WeeklyQuota.claudeResetWindow(samples)
        XCTAssertEqual(window?.from, saturday - 600)
        XCTAssertEqual(window?.length, 1200, "between the first Saturday's span and the next one's")
    }

    /// Review of #21: the samples only say the reset falls between Friday
    /// 10:00 and Saturday 12:00. A sample taken the next Friday at 12:00 may
    /// be from before that week's reset, so after Saturday 12:00 it is
    /// last week's — not kept until the Friday after.
    func testASampleInsideTheResetWindowEndsWithIt() {
        let week = 7 * 24 * 3600.0, hour = 3600.0, friday10 = 1_792_000_000.0
        let samples: [(Double, Double)] = [
            (friday10, 80), (friday10 + 26 * hour, 1),                  // reset somewhere in here
            (friday10 + 4 * 24 * hour, 40), (friday10 + week + 2 * hour, 85),
        ]
        let json = "{\"samples\":[" + samples.map { "{\"t\":\(Int($0.0 * 1000)),\"u\":{\"sd\":\($0.1)}}" }
            .joined(separator: ",") + "]}"
        let data = Data(json.utf8)
        let saturday12 = friday10 + week + 26 * hour
        XCTAssertEqual(WeeklyQuota.claudeRemaining(historyJSON: data, now: Date(timeIntervalSince1970: saturday12 - hour)), 15)
        XCTAssertNil(WeeklyQuota.claudeRemaining(historyJSON: data, now: Date(timeIntervalSince1970: saturday12 + 60)))

        // Once that window shows its reset, the new number lasts the week.
        let reset = json.replacingOccurrences(of: "]}", with: ",{\"t\":\(Int((friday10 + week + 5 * hour) * 1000)),\"u\":{\"sd\":3}}]}")
        XCTAssertEqual(WeeklyQuota.claudeRemaining(historyJSON: Data(reset.utf8),
                                                   now: Date(timeIntervalSince1970: saturday12 + 3 * 24 * hour)), 97)
    }

    /// Without a reset in the history, only the week-old rule applies; a
    /// small dip is not a reset.
    func testClaudeWithoutAResetKeepsTheWeekRule() {
        let t0 = 1_793_000_000_000.0, day = 24 * 3600 * 1000.0
        let json = #"{"samples":[{"t":\#(Int(t0)),"u":{"sd":40}},{"t":\#(Int(t0 + day)),"u":{"sd":37}}]}"#
        let data = Data(json.utf8)
        XCTAssertEqual(WeeklyQuota.claudeRemaining(historyJSON: data, now: Date(timeIntervalSince1970: (t0 + 6 * day) / 1000)), 63)
        XCTAssertNil(WeeklyQuota.claudeRemaining(historyJSON: data, now: Date(timeIntervalSince1970: (t0 + 9 * day) / 1000)))
    }

    /// The 11-02 `/usage` reply: Argon's weekly line, never a 5-hour one;
    /// without Argon, the tightest group.
    func testAntigravityBarFollowsArgon() {
        let text = """
        - **Gemini Models**
          - **Weekly Limit Remaining:** 92% remaining (resets Nov 03, 2026, 09:24 UTC)
          - **Five Hour Limit Remaining:** 3% remaining (resets Nov 02, 2026, 14:12 UTC)
        - **Claude and GPT models**
          - **Weekly Limit Remaining:** 17% remaining (resets Nov 03, 2026, 12:03 UTC)
        - **Gemini 4 Argon**
          - **Gemini 4 Argon Weekly Limit:** 22% remaining (resets Nov 03, 2026, 09:28 UTC)
        """
        XCTAssertEqual(WeeklyQuota.antigravityRemaining(usageText: text), 22)
        XCTAssertEqual(WeeklyQuota.antigravityBar([.init(name: "Gemini Models", remaining: 92), .init(name: "Claude·GPT", remaining: 17)]), 17)
        XCTAssertEqual(WeeklyQuota.antigravityGroups(usageText: text), [
            .init(name: "Gemini Models", remaining: 92),
            .init(name: "Claude·GPT", remaining: 17),
            .init(name: "Argon", remaining: 22),
        ])
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

    /// Health check #19: one failed lookup (no network yet after the lid
    /// opens) took that agent's bar away for a quarter hour, and every pet
    /// dropped two pixels with it. A failure keeps the last reading; only
    /// a tool that is not there, or one failing for two hours, loses it.
    func testAFailedLookupKeepsTheLastReading() {
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        let codex = WeeklyQuota.Reading(remaining: 52)
        let antigravity = WeeklyQuota.Reading(remaining: 22, groups: [.init(name: "Argon", remaining: 22)])
        var readings = WeeklyQuota.merge([:], with: ["codex": .found(codex), "google-antigravity": .found(antigravity),
                                                     "claude": .absent], now: t0)
        XCTAssertEqual(readings.keys.sorted(), ["codex", "google-antigravity"])

        readings = WeeklyQuota.merge(readings, with: ["codex": .failed, "google-antigravity": .failed], now: t0 + 60)
        XCTAssertEqual(readings["codex"]?.remaining, 52, "kept through a failure")
        XCTAssertEqual(readings["google-antigravity"]?.groups, antigravity.groups, "with its groups")

        readings = WeeklyQuota.merge(readings, with: ["codex": .failed, "google-antigravity": .found(.init(remaining: 20))],
                                     now: t0 + 60 + 2 * 3600)
        XCTAssertNil(readings["codex"], "failing for two hours: no bar")
        XCTAssertEqual(readings["google-antigravity"]?.remaining, 20)

        readings = WeeklyQuota.merge(readings, with: ["google-antigravity": .absent], now: t0 + 3 * 3600)
        XCTAssertNil(readings["google-antigravity"], "not there any more: no bar")
        XCTAssertNil(WeeklyQuota.merge([:], with: ["codex": .failed], now: t0)["codex"], "nothing to keep")
    }

    /// The failure clock starts at the first failure, not at the reading:
    /// a reading from before a night's sleep survives the first lookup
    /// after waking, which often finds no network yet.
    func testTheGraceCountsFromTheFirstFailure() {
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        var readings = WeeklyQuota.merge([:], with: ["codex": .found(.init(remaining: 40))], now: t0)
        let morning = t0 + 9 * 3600
        readings = WeeklyQuota.merge(readings, with: ["codex": .failed], now: morning)
        XCTAssertEqual(readings["codex"]?.remaining, 40)
        readings = WeeklyQuota.merge(readings, with: ["codex": .failed], now: morning + 3600)
        XCTAssertEqual(readings["codex"]?.remaining, 40)
        readings = WeeklyQuota.merge(readings, with: ["codex": .found(.init(remaining: 39))], now: morning + 3700)
        XCTAssertNil(readings["codex"]?.failingSince, "a fresh reading starts the clock over")
    }
}
