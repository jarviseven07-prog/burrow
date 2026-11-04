import XCTest
@testable import CodeIsland

/// 11-04: Jarvis took the weekly-quota bars out (「这些额度都去掉吧」) —
/// Claude's number could not be had both accurate and within its terms.
final class QuotaRemovedTests: XCTestCase {
    func testTheAntigravityUsageConversationIdIsForgotten() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "QuotaRemovedTests-\(UUID().uuidString)"))
        defaults.set("a-session-id", forKey: "quotaAntigravitySessionId")
        defaults.set(true, forKey: "unrelated")
        SettingsManager.forgetRemovedQuota(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "quotaAntigravitySessionId"))
        XCTAssertTrue(defaults.bool(forKey: "unrelated"))
    }

    /// Nothing of it is left to run or draw.
    func testNoQuotaCodeIsLeft() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for dir in ["Sources/CodeIsland", "Sources/CodeIslandCore"] {
            let folder = root.appendingPathComponent(dir)
            for file in try FileManager.default.contentsOfDirectory(atPath: folder.path) where file.hasSuffix(".swift") {
                let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
                for word in ["QuotaMonitor", "WeeklyQuota", "BurrowHealthBar", "quotaRemaining", "acp-cwd", "plan-usage-history"] {
                    XCTAssertFalse(text.contains(word), "\(word) in \(file)")
                }
            }
        }
    }
}
