import XCTest
import SwiftUI
import CodeIslandCore
@testable import CodeIsland

/// design/v21 C: Burrow's settings are the den's back.
@MainActor
final class BurrowDenBackTests: XCTestCase {
    func testTheGearTurnsTheDenOverAndClosingItTurnsItBack() {
        let app = AppState()
        app.showSettings()
        XCTAssertEqual(app.surface, .sessionList, "settings open the den, from anywhere")
        XCTAssertTrue(app.denShowsSettings)
        app.surface = .collapsed
        XCTAssertFalse(app.denShowsSettings, "the den always opens on its front")
        app.surface = .sessionList
        XCTAssertFalse(app.denShowsSettings)
    }

    /// The den holds an approval while it is open: its rows show it waiting.
    /// The back has no rows and stays open, so the card opens over it.
    func testARequestOpensItsCardOverTheBackButWaitsInTheDen() async throws {
        let app = AppState()
        var session = SessionSnapshot()
        session.source = "claude"
        app.sessions["s"] = session
        let event = try DemoRequests.hookEvent([
            "hook_event_name": "PermissionRequest", "session_id": "s",
            "tool_name": "Bash", "tool_input": ["command": "npm test"],
        ])
        let release = await DemoRequests.enqueuePermission(app, event: event)
        defer { release() }

        app.surface = .sessionList
        _ = app.showNextPending()
        XCTAssertEqual(app.surface, .sessionList, "the den's front holds it")

        app.showSettings()
        _ = app.showNextPending()
        XCTAssertEqual(app.surface, .approvalCard(sessionId: "s"))
        XCTAssertFalse(app.denShowsSettings)
    }

    /// Renders the back, with one pet unplugged, under its header; set
    /// BURROW_RENDER_OUT to a folder to keep the PNG.
    func testTheBackRenders() throws {
        let app = AppState()
        app.showSettings()
        let view = VStack(spacing: 0) {
            BurrowDenHeader(appState: app, notchWidth: 185).frame(height: 32)
            BurrowDenBack(shownConnections: ["claude": true, "codex": true, "opencode": true, "google-antigravity": false])
        }
        .frame(width: Burrow.denWidth)
        .background(Color.black)
        let image = try XCTUnwrap(OffscreenRender.rasterize(view))
        XCTAssertGreaterThan(image.height, 400, "header, pets, three rows and the licence line")
        if let out = ProcessInfo.processInfo.environment["BURROW_RENDER_OUT"] {
            try OffscreenRender.writePNG(image, to: "\(out)/den-back.png")
        }
    }

    /// The turn, frame by frame: a face shows at every angle but the edge-on
    /// one, and past half way the back reads the right way round.
    func testTheTurnShowsAFaceAllTheWay() throws {
        let app = AppState()
        let out = ProcessInfo.processInfo.environment["BURROW_RENDER_OUT"]
        for angle in [0.0, 45, 80, 100, 135, 180] {
            let view = BurrowFlipCard(angle: angle, front: BurrowDen(appState: app), back: BurrowDenBack())
                .frame(width: Burrow.denWidth)
                .background(Color.black)
            let image = try XCTUnwrap(OffscreenRender.rasterize(view))
            XCTAssertGreaterThan(image.height, 40, "angle \(angle)")
            if let out { try OffscreenRender.writePNG(image, to: "\(out)/turn-\(Int(angle)).png") }
        }
    }
}
