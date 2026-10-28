import AppKit
import SwiftUI
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The collapsed bar's right wing — quiet-hours moon, completion dot, question
/// badge, session count — must stay clear of the notch. Its room was sized for
/// the count and one badge; with tool status in simple mode nothing else pads
/// it, so a waiting question's badge slid under the notch, and the completion
/// dot beside it disappeared behind the notch altogether. A question the user
/// dismissed (#352) keeps that badge up until it is answered in the terminal.
@MainActor
final class CollapsedRightWingLayoutTests: XCTestCase {
    private let suiteName = "CollapsedRightWingLayoutTests"
    private var suite: UserDefaults!
    private var responses: [Task<Data, Never>] = []
    private var saved: [String: Any?] = [:]
    private let standardKeys = [
        SettingsKey.autoExpandOnQuestion, SettingsKey.smartSuppress,
    ]
    private let notch: CGFloat = 185

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        // AppState reads these from the standard defaults: the question stays
        // behind the collapsed bar's badge instead of opening its card.
        for key in standardKeys { saved[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
        MascotAnimationGate.shared.setPanelVisible(false)
    }

    override func tearDown() async throws {
        suite.removePersistentDomain(forName: suiteName)
        for key in standardKeys {
            if let value = saved[key] ?? nil { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        MascotAnimationGate.shared.setPanelVisible(true)
        try await super.tearDown()
    }

    func testQuestionBadgeAndCompletionDotStayClearOfTheNotch() async throws {
        for glance in [false, true] {
            let state = try await collapsedState(glance: glance)
            let g = try renderedGeometry(state)
            let name = "glance=\(glance)"
            XCTAssertNil(g.intrusion, "\(name): the right wing draws under the notch at \(g.intrusion ?? 0)pt")
            XCTAssertLessThanOrEqual(g.barRight, 620, "\(name): the bar runs past the panel window")
            XCTAssertGreaterThanOrEqual(g.barLeft, 0, "\(name): the bar runs past the panel window")
            await drain(state)
        }
    }

    func testTheBurrowHugsTheNotch() async throws {
        // Burrow: pets stand beside the notch in symmetric ears. Nothing is
        // drawn under the notch.
        let state = try await collapsedState(glance: true)
        let g = try renderedGeometry(state)
        XCTAssertNil(g.intrusion)
        // s1 waits on its question, s2 works: one pet on each side.
        let expected = BurrowLipMetrics.width(notchWidth: notch, pets: 2, hasOverflow: false)
        XCTAssertEqual(g.barRight - g.barLeft, expected, accuracy: 1)
        XCTAssertEqual((g.barLeft + g.barRight) / 2, 310, accuracy: 1, "the burrow is centred on the notch")
        await drain(state)
    }

    // MARK: - Fixture

    private func collapsedState(glance: Bool) async throws -> AppState {
        let state = AppState()
        var session = SessionSnapshot()
        session.source = "claude"
        session.cwd = "/Users/dev/code/web-app"
        var other = SessionSnapshot()
        other.source = "codex"
        other.cwd = "/Users/dev/code/api"
        state.sessions = ["s1": session, "s2": other]
        state.activeSessionId = "s1"
        state.refreshDerivedState()
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest", "session_id": "s1", "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [[
                "question": "Deploy?", "header": "Pick",
                "options": [["label": "Yes", "description": ""], ["label": "No", "description": ""]],
            ]]],
        ]
        let event = try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: payload)))
        responses.append(await startHookRequest { state.handleAskUserQuestion(event, continuation: $0) })
        XCTAssertEqual(state.hiddenPendingQuestionSessionId, "s1", "the question should wait behind the badge")
        state.glanceCompletionActive = glance
        return state
    }

    private func drain(_ state: AppState) async {
        for event in state.questionQueue.map(\.event) {
            state.handlePeerDisconnect(sessionId: event.sessionId ?? "default", agentId: event.agentId)
        }
        for task in responses { _ = try? await awaitValue(of: task) }
        responses = []
    }

    // MARK: - Rendering

    /// The real panel on a red backdrop: the bar's ends, and the first column
    /// under the physical notch where anything but the bar's black is drawn.
    private func renderedGeometry(_ state: AppState) throws -> (barLeft: CGFloat, barRight: CGFloat, intrusion: CGFloat?) {
        let windowWidth: CGFloat = 620, height: CGFloat = 64, notchHeight: CGFloat = 32
        let view = NotchPanelView(appState: state, hasNotch: true, notchHeight: notchHeight, notchW: notch, screenWidth: 1512)
            .environment(\.mascotStaticTime, 5.2)
            .defaultAppStorage(suite)
            .background(Color(red: 1, green: 0, blue: 0))
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: windowWidth, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        // Measured widths feed back into the bar on the next pass.
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage)
        let w = image.width, h = image.height
        let scale = CGFloat(w) / windowWidth
        let context = try XCTUnwrap(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let p = px + (y * w + x) * 4
            return (Int(p[0]), Int(p[1]), Int(p[2]))
        }
        func isBackdrop(_ c: (Int, Int, Int)) -> Bool { c.0 > 200 && c.1 < 60 && c.2 < 60 }
        func isBlack(_ c: (Int, Int, Int)) -> Bool { c.0 < 12 && c.1 < 12 && c.2 < 12 }
        let barRows = 0..<Int(notchHeight * scale)
        let mid = Int(notchHeight / 2 * scale)
        let left = try XCTUnwrap((0..<w).first { !isBackdrop(rgb($0, mid)) }, "no bar rendered")
        let right = try XCTUnwrap((0..<w).reversed().first { !isBackdrop(rgb($0, mid)) })
        // 2pt in from the notch's sides: the island's antialiased corners.
        let notchLeft = Int(((windowWidth - notch) / 2 + 2) * scale), notchRight = Int(((windowWidth + notch) / 2 - 2) * scale)
        let intrusion = (notchLeft..<notchRight).first { x in
            barRows.contains { y in let c = rgb(x, y); return !isBlack(c) && !isBackdrop(c) }
        }
        return (CGFloat(left) / scale, CGFloat(right + 1) / scale, intrusion.map { CGFloat($0) / scale })
    }
}
