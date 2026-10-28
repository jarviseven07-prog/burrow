import AppKit
import SwiftUI
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Every expanded surface has to fit the panel window: what doesn't is cut
/// off by the window's bottom edge, out of reach. Rendered offscreen on a red
/// backdrop (PanelHost) so the panel's bottom edge can be read from pixels.
@MainActor
final class PanelFitLayoutTests: XCTestCase {
    private var sandbox: DefaultsSandbox?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        sandbox = DefaultsSandbox(keys: DefaultsSandbox.allSettingsKeys)
        MascotAnimationGate.shared.setPanelVisible(false)
    }

    override func tearDown() {
        MascotAnimationGate.shared.setPanelVisible(true)
        sandbox?.restore()
        super.tearDown()
    }

    // MARK: - Session list

    func testFewTallSessionsStayInsideTheWindow() throws {
        // Four sessions — under the five the window is sized for — but with
        // a task list, an approval row and a recap they ran ~150pt past the
        // 510pt window, footer and all.
        let state = try tallSessions(count: 4)
        defer { state.release() }
        let panel = try PanelHost(state.state, notchHeight: 32)
        defer { panel.close() }
        panel.settle()
        XCTAssertGreaterThan(try panel.gapUnderPanel(), 0, "the session list runs off the bottom of the window")
    }

    func testTallSessionsAtALargeFontStayInsideTheWindow() throws {
        UserDefaults.standard.set(16, forKey: SettingsKey.contentFontSize)
        let state = try tallSessions(count: 4)
        defer { state.release() }
        let panel = try PanelHost(state.state, notchHeight: 37)
        defer { panel.close() }
        panel.settle()
        XCTAssertGreaterThan(try panel.gapUnderPanel(), 0, "the session list runs off the bottom of the window")
    }

    func testSqueezedBranchKeepsAFewCharacters() {
        // A long project name used to leave the branch an icon and "…".
        let short = BranchLabelMetrics.minimumWidth(for: "main", fontSize: 11)
        let long = BranchLabelMetrics.minimumWidth(for: "feature/very-long-branch-name-for-onboarding-flow", fontSize: 11)
        let twelve = BranchLabelMetrics.minimumWidth(for: String(repeating: "x", count: 12), fontSize: 11)
        XCTAssertLessThan(short, twelve, "a short branch must not be padded")
        XCTAssertEqual(long, twelve, accuracy: 1, "a long branch keeps room for twelve characters")
    }

    // MARK: - Question card

    func testQuestionWithManyOptionsKeepsItsButtonsInsideTheWindow() async throws {
        // Ten options with descriptions used to push option 10, "Other" and
        // the Dismiss / Skip row past the bottom of the 510pt window.
        let state = AppState()
        var s = SessionSnapshot()
        s.source = "claude"
        s.cwd = "/Users/dev/code/web-app"
        s.status = .waitingQuestion
        state.sessions = ["q": s]
        state.activeSessionId = "q"
        let regions = (1...10).map { ("region-\($0)", Optional("Latency to the team: medium")) }
        let release = try await DemoRequests.enqueueQuestion(state, sessionId: "q", cwd: "/Users/dev/code/web-app", items: [
            ("Which region should the staging stack deploy to?", "Region", regions, false),
        ])
        defer { release() }
        state.refreshDerivedState()
        state.surface = .questionCard(sessionId: "q")
        let panel = try PanelHost(state, notchHeight: 32)
        defer { panel.close() }
        panel.settle()
        XCTAssertGreaterThan(try panel.gapUnderPanel(), 0, "the question card runs off the bottom of the window")
    }

    // MARK: - Approval card

    func testApprovalCardNamesTheSessionAsking() {
        // With several sessions queued, a card has to say whose command it is
        // about to allow. Burrow: the pet's stage subtitle names the agent and
        // the project, and the card's place in the queue.
        var s = SessionSnapshot()
        s.source = "codex"
        s.cwd = "/Users/dev/code/api-server"
        let queue = NotchCardQueueLabel.text(position: 1, total: 2)
        XCTAssertNotNil(queue)
        let subtitle = BurrowCardSubtitle.text(session: s, extra: queue)
        XCTAssertTrue(subtitle.contains("Codex"), subtitle)
        XCTAssertTrue(subtitle.contains("api-server"), subtitle)
        XCTAssertTrue(subtitle.contains(queue!), subtitle)
    }

    // MARK: - Fixtures

    private struct Demo {
        let state: AppState
        let release: () -> Void
    }

    private func tallSessions(count: Int) throws -> Demo {
        let state = AppState()
        for index in 0..<count {
            var s = SessionSnapshot(startTime: Date().addingTimeInterval(-600))
            s.source = "claude"
            s.cwd = "/Users/dev/code/project-\(index)"
            s.gitBranch = "feat/branch-\(index)"
            s.status = .running
            s.currentTool = "Edit"
            s.toolDescription = "src/components/Dashboard.tsx"
            s.lastUserPrompt = "Add filters to the dashboard page"
            s.addRecentMessage(ChatMessage(isUser: true, text: "Add filters to the dashboard page"))
            s.addRecentMessage(ChatMessage(isUser: false, text: "Adding a date-range and status filter bar above the orders table."))
            s.agentTasks = AgentTaskList(items: (1...5).map {
                AgentTaskItem(id: "t\($0)", title: "Task \($0)", status: $0 < 3 ? .completed : ($0 == 3 ? .inProgress : .pending))
            })
            state.sessions["s\(index)"] = s
        }
        state.activeSessionId = "s0"
        state.refreshDerivedState()
        state.surface = .sessionList
        return Demo(state: state, release: {})
    }
}
