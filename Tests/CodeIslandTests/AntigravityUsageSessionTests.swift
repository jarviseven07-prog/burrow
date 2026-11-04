import XCTest
@testable import CodeIsland

/// Health check 2026-11-04 #8: every quota lookup opened a new Antigravity
/// conversation for `/usage` and never deleted it, about 0.5 MB each, every
/// quarter hour (97 of them, 51 MB, by 11-04). ACP has no delete, but it
/// can resume: Burrow keeps one conversation and asks in it every time.
final class AntigravityUsageSessionTests: XCTestCase {
    func testTheSavedConversationIsResumed() {
        var created = 0
        let chosen = QuotaSources.usageSession(saved: "s1", resume: { $0 == "s1" }, create: { created += 1; return "new" })
        XCTAssertEqual(chosen?.id, "s1")
        XCTAssertEqual(chosen?.isNew, false)
        XCTAssertEqual(created, 0, "no new conversation")
    }

    func testANewOneOnlyWhenThereIsNoneToResume() {
        let gone = QuotaSources.usageSession(saved: "old", resume: { _ in false }, create: { "new" })
        XCTAssertEqual(gone?.id, "new")
        XCTAssertEqual(gone?.isNew, true)
        let first = QuotaSources.usageSession(saved: nil, resume: { _ in XCTFail("nothing to resume"); return false },
                                              create: { "new" })
        XCTAssertEqual(first?.id, "new")
        XCTAssertNil(QuotaSources.usageSession(saved: nil, resume: { _ in false }, create: { nil }))
    }
}
