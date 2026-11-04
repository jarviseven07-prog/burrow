import XCTest
@testable import CodeIsland

/// Health check 2026-11-04 #4: a click elsewhere did not close the den's
/// back when it landed inside the panel window, which is transparent and
/// sized for a ten-row den — on Jarvis's Mac 620×895 points at x 446 on a
/// 1512×982 screen, 41% of its width and 91% of its height. Only the
/// island itself counts as a click on Burrow now.
final class PanelClickOutsideTests: XCTestCase {
    private let panel = CGRect(x: 446, y: 87, width: 620, height: 895)

    func testTheIslandHangsFromTheWindowsTopCentre() {
        let open = NotchIslandGeometry(centerOffset: 0, width: 380, height: 300, topExtension: 8, bottomRadius: 18, expanded: true)
        XCTAssertEqual(open.screenRect(inPanel: panel), CGRect(x: 566, y: 682, width: 380, height: 300))
        let shifted = NotchIslandGeometry(centerOffset: 12, width: 200, height: 32, topExtension: 0, bottomRadius: 8, expanded: false)
        XCTAssertEqual(shifted.screenRect(inPanel: panel).midX, panel.midX + 12)
    }

    func testAClickInTheMiddleOfTheScreenIsNotOnTheIsland() {
        let back = NotchIslandGeometry(centerOffset: 0, width: 380, height: 300, topExtension: 8, bottomRadius: 18, expanded: true)
        let island = back.screenRect(inPanel: panel)
        let editor = CGPoint(x: 756, y: 450)
        XCTAssertTrue(panel.contains(editor), "what kept the back open")
        XCTAssertFalse(island.contains(editor))
        XCTAssertTrue(island.contains(CGPoint(x: 756, y: 900)))
    }
}

/// Health check #22: with "hide when no session" on and nothing running,
/// the panel was ordered out, so the menu bar's "Settings…" turned over a
/// den nobody could see. Settings now bring the panel up.
final class SettingsWithHiddenPanelTests: XCTestCase {
    func testSettingsKeepTheHiddenPanelUp() {
        XCTAssertTrue(PanelWindowController.hidesWithNoSession(hideWhenNoSession: true, activeSessionCount: 0, showsSettings: false))
        XCTAssertFalse(PanelWindowController.hidesWithNoSession(hideWhenNoSession: true, activeSessionCount: 0, showsSettings: true))
        XCTAssertFalse(PanelWindowController.hidesWithNoSession(hideWhenNoSession: true, activeSessionCount: 1, showsSettings: false))
        XCTAssertFalse(PanelWindowController.hidesWithNoSession(hideWhenNoSession: false, activeSessionCount: 0, showsSettings: false))
    }

    @MainActor
    func testClosingTheBackLetsThePanelHideAgain() {
        let app = AppState()
        app.showSettings()
        XCTAssertTrue(app.denShowsSettings)
        XCTAssertFalse(PanelWindowController.hidesWithNoSession(hideWhenNoSession: true, activeSessionCount: 0,
                                                                 showsSettings: app.denShowsSettings))
        app.closeIsland()
        XCTAssertTrue(PanelWindowController.hidesWithNoSession(hideWhenNoSession: true, activeSessionCount: 0,
                                                                showsSettings: app.denShowsSettings))
    }
}
