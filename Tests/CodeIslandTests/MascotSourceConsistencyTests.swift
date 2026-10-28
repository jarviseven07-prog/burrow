import XCTest
@testable import CodeIslandCore

/// Left mascot and right host badge must agree on which agent/app a card represents.
final class MascotSourceConsistencyTests: XCTestCase {

    private func makeSession(source: String, termBundleId: String?) -> SessionSnapshot {
        var session = SessionSnapshot()
        session.source = source
        session.termBundleId = termBundleId
        return session
    }

    func testClaudeCLIInsideAntigravityIsForeignHosted() {
        let session = makeSession(source: "claude", termBundleId: "com.google.antigravity")
        XCTAssertEqual(session.mascotSource, "claude")
        XCTAssertTrue(session.isIDETerminal)
        XCTAssertTrue(session.isCLIHostedInForeignApp)
    }

    func testCodexDesktopInfersMascotWhenSourceEmpty() {
        let session = makeSession(source: "", termBundleId: "com.openai.codex")
        XCTAssertEqual(session.mascotSource, "codex")
        XCTAssertFalse(session.isCLIHostedInForeignApp)
    }

    func testTerminalBadgeLabelFollowsCLIWhenHostedInForeignApp() {
        let session = makeSession(source: "claude", termBundleId: "com.google.antigravity")
        XCTAssertEqual(session.terminalName, "Antigravity")
        XCTAssertEqual(session.terminalBadgeLabel, "Claude")
        XCTAssertEqual(session.mascotSource, "claude")
    }

}
