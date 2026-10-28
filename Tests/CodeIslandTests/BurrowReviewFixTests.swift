import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Fixes from the 2026-10-15 review (design/review/2026-10-15-code-review.md):
/// reopening a dismissed approval, approvals in the agent's own voice, the
/// night light over a passing reaction, a den that holds still under the
/// pointer.
@MainActor
final class BurrowReviewFixTests: XCTestCase {
    private var appState: AppState!
    private var pending: [Task<Data, Never>] = []
    private var played: [String] = []
    private var saved: [String: Any?] = [:]
    private let keys = [
        SettingsKey.autoExpandOnPermission, SettingsKey.autoExpandOnQuestion,
        SettingsKey.smartSuppress, SettingsKey.completionNotificationStyle,
        SettingsKey.soundEnabled,
        SettingsKey.soundApprovalNeeded, SettingsKey.quietHoursEnabled,
    ]

    override func setUp() async throws {
        try await super.setUp()
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnPermission)
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnQuestion)
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
        UserDefaults.standard.set("glance", forKey: SettingsKey.completionNotificationStyle)
        UserDefaults.standard.set(true, forKey: SettingsKey.soundEnabled)
        UserDefaults.standard.set(true, forKey: SettingsKey.soundApprovalNeeded)
        UserDefaults.standard.set(false, forKey: SettingsKey.quietHoursEnabled)
        played = []
        SoundManager.shared.playSink = { [weak self] name in self?.played.append(name) }
        SceneMuteMonitor.shared.resetForTesting()
        pending = []
        appState = AppState()
    }

    override func tearDown() async throws {
        let waiters = appState.permissionQueue.map(\.event) + appState.questionQueue.map(\.event)
        for event in waiters {
            appState.handlePeerDisconnect(sessionId: event.sessionId ?? "default", agentId: event.agentId)
        }
        for t in pending { _ = try? await awaitValue(of: t) }
        appState = nil
        SoundManager.shared.playSink = nil
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
        try await super.tearDown()
    }

    // MARK: - Review #1: a dismissed approval reopened by hand stays up

    func testReopenedDismissedApprovalStaysUpAndAnswersItsShortcut() async throws {
        try await requestApproval("R1")
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "R1"))
        appState.dismissPermissionPrompt(expectedSessionId: "R1")
        XCTAssertFalse(appState.visiblePermissionSessionIds.contains("R1"))

        // Its den row (or its lit pet) opens it again.
        appState.reopenPermissionCard(sessionId: "R1")
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "R1"))
        XCTAssertTrue(appState.visiblePermissionSessionIds.contains("R1"), "reopening takes back the dismiss")

        // Anything that re-evaluates the queue leaves it up…
        appState.showNextPending()
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "R1"))
        // …and the approve shortcut approves instead of closing it.
        XCTAssertEqual(appState.performCardShortcut(.approve), .acted(sessionId: "R1"))
        XCTAssertTrue(appState.permissionQueue.isEmpty)
    }

    // MARK: - Review #3: approvals chime in the agent's own key

    func testApprovalChimesInTheAgentsOwnVoice() async throws {
        try await requestApproval("CX", source: "codex")
        XCTAssertEqual(played, ["burrow_approval_codex"])
    }

    func testClaudesApprovalKeepsTheBaseVoice() async throws {
        try await requestApproval("CL", source: "claude")
        XCTAssertEqual(played, ["burrow_approval"])
    }

    // MARK: - Review #5: waiting on you outranks a passing reaction

    func testWaitingPetIsLitEvenWhileAReactionPlays() {
        for status in [MascotAgentStatus.waitingApproval, .waitingQuestion] {
            for reaction in [PetState.heart, .celebrate, .dizzy] {
                let state = MascotView.petState(status: status, reaction: reaction, animating: true)
                XCTAssertEqual(state, .attention, "\(status) under \(reaction)")
                XCTAssertTrue(BurrowLipMetrics.isLit(state))
            }
        }
        XCTAssertEqual(MascotView.petState(status: .idle, reaction: .heart, animating: true), .heart,
                       "a reaction still shows when nothing waits")
    }

    // MARK: - Review #2: the den holds still under the pointer

    func testFrozenOrderKeepsRowsInPlace() {
        var freeze = SessionOrderFreeze()
        freeze.freeze(["a", "b", "c"])
        // b starts waiting on you and jumps to the top of the live order; d starts.
        XCTAssertEqual(freeze.apply(["b", "a", "d", "c"]), ["a", "b", "c", "d"])
        // c ends: it drops out, nothing else moves.
        XCTAssertEqual(freeze.apply(["b", "a", "d"]), ["a", "b", "d"])
        freeze.thaw()
        XCTAssertEqual(freeze.apply(["b", "a", "d"]), ["b", "a", "d"])
    }

    // MARK: - Helpers

    private func requestApproval(_ sid: String, source: String? = nil) async throws {
        var payload: [String: Any] = [
            "hook_event_name": "PermissionRequest", "session_id": sid, "tool_name": "Bash",
            "tool_input": ["command": "echo \(sid)"],
        ]
        if let source { payload["_source"] = source }
        let e = try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: payload)))
        pending.append(await startHookRequest { [appState] in appState!.handlePermissionRequest(e, continuation: $0) })
    }
}
