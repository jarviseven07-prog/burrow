import XCTest
@testable import CodeIsland
import CodeIslandCore

/// A Claude Desktop Code-tab session is named the way Claude Desktop's
/// sidebar names it, not after its scratch folder.
final class ClaudeDesktopTitleTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "burrow-desktop-title-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/claude-code-sessions/acct/org", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func writeRecord(_ host: String, title: String?) throws {
        var json: [String: Any] = ["sessionId": host, "cliSessionId": "cli-1", "sessionSettings": ["title": "not this"]]
        if let title { json["title"] = title }
        try JSONSerialization.data(withJSONObject: json)
            .write(to: URL(fileURLWithPath: root + "/claude-code-sessions/acct/org/\(host).json"))
    }

    func testReadsTheSidebarTitle() throws {
        try writeRecord("local_abc-1", title: "  Codeisland 定制化改造 ")
        let cache = ClaudeDesktopTitleCache(supportDirectory: root)
        XCTAssertEqual(cache.title(hostSessionId: "local_abc-1"), "Codeisland 定制化改造")
        XCTAssertNil(cache.title(hostSessionId: "local_missing"))
        XCTAssertNil(cache.title(hostSessionId: "../etc/passwd"), "only well-formed host ids are looked up")
    }

    func testRecheckedOnlyAfterTheIntervalAndWhenChanged() throws {
        try writeRecord("local_abc-2", title: "First")
        var clock = Date(timeIntervalSince1970: 1_000)
        let cache = ClaudeDesktopTitleCache(supportDirectory: root, recheckInterval: 30, now: { clock })
        XCTAssertEqual(cache.title(hostSessionId: "local_abc-2"), "First")
        try writeRecord("local_abc-2", title: "Renamed")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: root + "/claude-code-sessions/acct/org/local_abc-2.json")
        clock += 10
        XCTAssertEqual(cache.title(hostSessionId: "local_abc-2"), "First", "not re-read within 30s")
        clock += 30
        XCTAssertEqual(cache.title(hostSessionId: "local_abc-2"), "Renamed")
    }

    func testBurrowNamePrefersTheTitleOverTheFolder() {
        var session = SessionSnapshot()
        session.cwd = "/Users/me/Library/Application Support/Claude/scratch-workspaces/a/b/scratch-2026-10-15-f53f58"
        XCTAssertEqual(session.burrowName, "scratch-2026-10-15-f53f58")
        session.sessionTitle = "设计新图标"
        XCTAssertEqual(session.burrowName, "设计新图标")
    }

    func testInjectedRemindersAreNotThePrompt() {
        XCTAssertEqual(JSONLTailer.stripDisplayWrappers("<system-reminder>The user started…</system-reminder>\n帮我改图标"),
                       "\n帮我改图标")
    }
}
