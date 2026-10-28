import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Zed (#307) hands its integrated terminal a rebuilt environment with no
/// bundle id; TERM_PROGRAM alone must still mark it as an IDE terminal.
final class IDETerminalDetectionTests: XCTestCase {
    func testZedSessionWithoutABundleIdStillCountsAsAnIDETerminal() {
        var session = SessionSnapshot()
        session.termApp = "zed"
        XCTAssertTrue(
            session.isIDETerminal,
            "Zed gives its terminal a rebuilt env with no __CFBundleIdentifier"
        )
    }

    func testAPlainTerminalWithoutABundleIdIsStillNotAnIDETerminal() {
        var session = SessionSnapshot()
        session.termApp = "Ghostty"
        XCTAssertFalse(session.isIDETerminal)
    }
}
