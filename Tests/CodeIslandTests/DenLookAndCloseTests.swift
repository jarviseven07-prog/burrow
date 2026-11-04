import XCTest
import CodeIslandCore
@testable import CodeIsland

/// The den's look (embers and sparks), closing it, and its rows under the
/// pointer — health check 2026-11-04 #20, #11, #15.
@MainActor
final class DenLookAndCloseTests: XCTestCase {
    /// #20: ⌘, or the gear on a card opened the den on its back, but
    /// switching the surface to the den counted as a look, so an ember and a
    /// spark went out though no row was ever on screen.
    func testSettingsAloneAreNotALookAtTheDen() {
        let app = AppState()
        app.showSettings()
        XCTAssertTrue(app.denShowsSettings)
        XCTAssertEqual(app.denSeenAt, .distantPast, "the back shows no rows")
        app.surface = .collapsed
        XCTAssertEqual(app.denSeenAt, .distantPast, "closing the back is not one either")
    }

    func testTurningTheBackToTheFrontIsALook() {
        let app = AppState()
        app.showSettings()
        app.denShowsSettings = false
        let looked = app.denSeenAt
        XCTAssertGreaterThan(looked, .distantPast)
        XCTAssertEqual(app.denLookBefore, .distantPast, "the den marks what finished since the look before")
        app.denShowsSettings = true
        XCTAssertGreaterThanOrEqual(app.denSeenAt, looked, "leaving the front for the back ends the look")
    }

    func testTheGearInAnOpenDenKeepsTheLookItWas() {
        let app = AppState()
        app.surface = .sessionList
        let opened = app.denSeenAt
        XCTAssertGreaterThan(opened, .distantPast)
        app.showSettings()
        let flipped = app.denSeenAt
        XCTAssertGreaterThanOrEqual(flipped, opened)
        app.surface = .collapsed
        XCTAssertEqual(app.denSeenAt, flipped, "the back closing adds no look")
    }
}

/// #11: the card a request opens, pushed aside by settings or held by the
/// open den, opens again when a click elsewhere or the toggle shortcut
/// closes the den — not only when the pointer leaves it.
@MainActor
final class DenCloseReopensHeldCardTests: XCTestCase {
    private func waitingApproval(_ app: AppState) async throws -> () -> Void {
        var session = SessionSnapshot()
        session.source = "claude"
        app.sessions["s"] = session
        let event = try DemoRequests.hookEvent([
            "hook_event_name": "PermissionRequest", "session_id": "s",
            "tool_name": "Bash", "tool_input": ["command": "npm test"],
        ])
        return await DemoRequests.enqueuePermission(app, event: event)
    }

    func testClosingTheBackBringsBackTheCardItPushedAside() async throws {
        let app = AppState()
        let release = try await waitingApproval(app)
        defer { release() }
        _ = app.showNextPending()
        XCTAssertEqual(app.surface, .approvalCard(sessionId: "s"))
        app.showSettings()
        XCTAssertEqual(app.surface, .sessionList, "the back pushed the card aside")
        app.closeIsland()
        XCTAssertEqual(app.surface, .approvalCard(sessionId: "s"))
    }

    func testTheToggleClosingTheDenOpensTheRequestItHeld() async throws {
        let app = AppState()
        app.surface = .sessionList
        let release = try await waitingApproval(app)
        defer { release() }
        _ = app.showNextPending()
        XCTAssertEqual(app.surface, .sessionList, "held by the open den")
        app.closeIsland(cancellingCompletions: false)
        XCTAssertEqual(app.surface, .approvalCard(sessionId: "s"))
    }

    func testNothingWaitingStaysClosed() {
        let app = AppState()
        app.showSettings()
        app.closeIsland()
        XCTAssertEqual(app.surface, .collapsed)
    }
}

/// #15: a finished row reaching its three minutes was taken out while the
/// pointer was over the den; the order freeze keeps places, not rows, so
/// the rows below moved up and a click could land on another conversation.
@MainActor
final class DenRowsUnderPointerTests: XCTestCase {
    func testAFinishedRowWaitsWhileThePointerIsOnTheDen() {
        let fourMinutesAgo = Date().addingTimeInterval(-4 * 60)
        XCTAssertFalse(AppState.removesFinishedRow(lastActivity: fourMinutesAgo, denHoldsRows: true))
        XCTAssertTrue(AppState.removesFinishedRow(lastActivity: fourMinutesAgo, denHoldsRows: false))
        XCTAssertFalse(AppState.removesFinishedRow(lastActivity: Date(), denHoldsRows: false), "its three minutes still run")
    }

    func testOnlyTheOpenFrontUnderThePointerHoldsItsRows() {
        let app = AppState()
        app.surface = .sessionList
        app.denPointerInside = true
        XCTAssertTrue(app.denHoldsItsRows)
        app.denShowsSettings = true
        XCTAssertFalse(app.denHoldsItsRows, "the back has no rows")
        app.denShowsSettings = false
        app.surface = .collapsed
        XCTAssertFalse(app.denPointerInside, "a den closed under the pointer lets go")
        app.surface = .sessionList
        XCTAssertFalse(app.denHoldsItsRows)
    }
}
