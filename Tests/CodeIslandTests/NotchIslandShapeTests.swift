import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The island's silhouette moves with Core Animation (NotchIslandShapeDriver):
/// the springs must be NotchAnimation's, every change must be additive so a
/// retarget mid-spring stays continuous, and NotchPanelView must hand the
/// driver the same geometry it used to draw itself.
@MainActor
final class NotchIslandShapeTests: XCTestCase {
    private let collapsed = NotchIslandGeometry(centerOffset: -9, width: 225, height: 32, topExtension: 3, bottomRadius: 10, expanded: false)
    private let expanded = NotchIslandGeometry(centerOffset: 0, width: 580, height: 116, topExtension: 14, bottomRadius: 24, expanded: true)

    func testSpringIsSwiftUIsResponseAndDamping() {
        let spring = NotchSpring(response: 0.42, dampingFraction: 0.82)
        let omega = 2 * CGFloat.pi / 0.42
        XCTAssertEqual(spring.stiffness, omega * omega, accuracy: 0.001)
        XCTAssertEqual(spring.damping, 2 * 0.82 * omega, accuracy: 0.001)
        let a = spring.animation(keyPath: "bounds.size.width")
        XCTAssertEqual(a.mass, 1)
        XCTAssertEqual(a.duration, a.settlingDuration)
        // Close is critically damped: damping = 2√k.
        let close = NotchSpring(response: 0.38, dampingFraction: NotchAnimationMetrics.closeDamping)
        XCTAssertEqual(close.damping, 2 * sqrt(close.stiffness), accuracy: 0.001)
    }

    func testFirstGeometryIsPlacedWithoutAnimation() throws {
        let driver = NotchIslandShapeDriver()
        driver.setBounds(CGRect(x: 0, y: 0, width: 620, height: 300))
        driver.update(collapsed)
        let body = try bodyLayer(driver)
        XCTAssertNil(body.animationKeys())
        XCTAssertEqual(body.bounds.size, CGSize(width: 225, height: 32))
        XCTAssertEqual(body.position, CGPoint(x: 310 - 9, y: 300), "hangs from the top edge, 9pt left")
        XCTAssertEqual(body.cornerRadius, 10)
    }

    func testOpenAndCloseAreAdditiveSpringsInTheirDirection() throws {
        let driver = NotchIslandShapeDriver()
        driver.setBounds(CGRect(x: 0, y: 0, width: 620, height: 300))
        driver.update(collapsed)
        driver.update(expanded)
        let body = try bodyLayer(driver)
        XCTAssertEqual(body.bounds.size, CGSize(width: 580, height: 116), "the model is the target at once")

        let width = try spring(on: body, keyPath: "bounds.size.width")
        XCTAssertTrue(width.isAdditive)
        XCTAssertEqual(width.fromValue as? CGFloat, 225 - 580)
        XCTAssertEqual(width.toValue as? CGFloat, 0)
        XCTAssertEqual(width.damping, NotchSpring.open.damping, accuracy: 0.001)
        XCTAssertEqual(try spring(on: body, keyPath: "position.x").fromValue as? CGFloat, -9)
        XCTAssertEqual(try spring(on: body, keyPath: "bounds.size.height").fromValue as? CGFloat, 32 - 116)

        driver.update(collapsed)
        let widths = body.animationKeys()!.filter { $0.hasPrefix("bounds.size.width#") }
        XCTAssertEqual(widths.count, 2, "the close spring is added on top of the open one")
        let close = try XCTUnwrap(widths.compactMap { body.animation(forKey: $0) as? CASpringAnimation }
            .first { ($0.fromValue as? CGFloat) == 580 - 225 })
        XCTAssertEqual(close.damping, NotchSpring.close.damping, accuracy: 0.001)
    }

    func testShouldersFollowTheTopCorners() throws {
        let driver = NotchIslandShapeDriver()
        driver.setBounds(CGRect(x: 0, y: 0, width: 620, height: 300))
        driver.update(collapsed)
        driver.update(expanded)
        let layers = try XCTUnwrap(driver.maskLayer.sublayers)
        let left = try XCTUnwrap(layers[1] as? CAShapeLayer), right = try XCTUnwrap(layers[2] as? CAShapeLayer)
        XCTAssertEqual(left.position, CGPoint(x: 310 - 290, y: 300))
        XCTAssertEqual(right.position, CGPoint(x: 310 + 290, y: 300))
        // Each corner moves by the body's centre ± half its width change.
        XCTAssertEqual(try spring(on: left, keyPath: "position.x").fromValue as? CGFloat, (-9 - 112.5) - (-290))
        XCTAssertEqual(try spring(on: right, keyPath: "position.x").fromValue as? CGFloat, (-9 + 112.5) - 290)
        XCTAssertEqual(right.path?.boundingBox.width ?? 0, 14, accuracy: 0.001)
        XCTAssertNotNil(right.animation(forKey: "path"), "the shoulder grows with the open spring")
    }

    func testCollapsedChangesSettleWithoutBounce() throws {
        let driver = NotchIslandShapeDriver()
        driver.update(collapsed)
        var wider = collapsed
        wider.width += NotchHoverInteraction.prehoverWidthDelta
        driver.update(wider)
        let width = try spring(on: try bodyLayer(driver), keyPath: "bounds.size.width")
        XCTAssertEqual(width.damping, NotchSpring.settle.damping, accuracy: 0.001)
        XCTAssertEqual(width.damping, 2 * sqrt(width.stiffness), accuracy: 0.001)
    }

    func testUnchangedGeometryAddsNothing() throws {
        let driver = NotchIslandShapeDriver()
        driver.update(collapsed)
        driver.update(collapsed)
        XCTAssertNil(try bodyLayer(driver).animationKeys())
    }

    /// The real panel with a driver: it reports the island instead of
    /// drawing it, collapsed at the notch plus two ears and expanded at the
    /// panel's width and measured height.
    func testPanelHandsTheDriverItsIsland() async throws {
        let suiteName = "NotchIslandShapeTests"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName) }
        _ = NSApplication.shared

        let state = AppState()
        var session = SessionSnapshot()
        session.source = "claude"
        session.cwd = "/Users/dev/code/web-app"
        session.status = .running
        session.currentTool = "Bash"
        state.sessions = ["s1": session]
        state.activeSessionId = "s1"
        state.refreshDerivedState()

        let driver = NotchIslandShapeDriver()
        let view = NotchPanelView(appState: state, hasNotch: true, notchHeight: 32, notchW: 185, screenWidth: 1512, islandDriver: driver)
            .environment(\.mascotStaticTime, 5.2)
            .defaultAppStorage(suite)
            .background(Color(red: 1, green: 0, blue: 0))
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        func settle() {
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
        }

        settle()
        let bar = try XCTUnwrap(driver.target)
        XCTAssertFalse(bar.expanded)
        // Burrow: the working pet stands beside the notch, so the island is
        // the notch plus two even ears, centred, and no taller than the menu
        // bar — nothing covers the windows below.
        XCTAssertEqual(bar.width, BurrowLipMetrics.width(notchWidth: 185, pets: 1, hasOverflow: false), accuracy: 0.5)
        XCTAssertEqual(bar.width, 257, accuracy: 0.5, "a working pet's sign never widens the island")
        XCTAssertEqual(bar.centerOffset, 0, accuracy: 0.01)
        XCTAssertEqual(bar.height, 32)
        XCTAssertEqual(bar.bottomRadius, BurrowLipMetrics.bottomRadius)
        XCTAssertFalse(try drawsBlack(host, row: 16, from: 240, to: 380), "with a driver the silhouette is Core Animation's, not SwiftUI's")

        state.surface = .sessionList
        settle()
        let panel = try XCTUnwrap(driver.target)
        XCTAssertTrue(panel.expanded)
        XCTAssertEqual(panel.width, Burrow.denWidth)
        XCTAssertEqual(panel.centerOffset, 0)
        XCTAssertGreaterThan(panel.height, 32 + 40, "the measured session list")
        XCTAssertEqual(panel.topExtension, 14)
        XCTAssertEqual(panel.bottomRadius, Burrow.denRadius)

        state.surface = .collapsed
        settle()
        XCTAssertEqual(driver.target, bar)
    }

    // MARK: - Helpers

    private func bodyLayer(_ driver: NotchIslandShapeDriver) throws -> CALayer {
        try XCTUnwrap(driver.maskLayer.sublayers?.first)
    }

    private func spring(on layer: CALayer, keyPath: String) throws -> CASpringAnimation {
        let key = try XCTUnwrap(layer.animationKeys()?.last { $0.hasPrefix(keyPath + "#") }, "no \(keyPath) spring")
        return try XCTUnwrap(layer.animation(forKey: key) as? CASpringAnimation)
    }

    /// Whether any pixel in `row` between two x positions (points) is black.
    private func drawsBlack(_ host: NSView, row: CGFloat, from: CGFloat, to: CGFloat) throws -> Bool {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let y = Int(row * scale)
        return (Int(from * scale)..<Int(to * scale)).contains { x in
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return c.redComponent < 0.05 && c.greenComponent < 0.05 && c.blueComponent < 0.05
        }
    }
}
