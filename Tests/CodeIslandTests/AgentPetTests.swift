import XCTest
@testable import CodeIsland
import CodeIslandCore

/// One pet per agent, however many conversations it has open: four agents
/// with three conversations each are four pets, not twelve.
@MainActor
final class AgentPetTests: XCTestCase {
    private func session(_ source: String, _ status: AgentStatus, started: TimeInterval) -> SessionSnapshot {
        var s = SessionSnapshot()
        s.source = source
        s.status = status
        s.startTime = Date(timeIntervalSince1970: started)
        return s
    }

    func testConversationsShareTheirAgentsPet() {
        let state = AppState()
        state.sessions = [
            "c1": session("claude", .idle, started: 1),
            "c2": session("claude", .running, started: 2),
            "c3": session("claude", .idle, started: 3),
            "x1": session("codex", .idle, started: 4),
        ]
        let layout = BurrowResidents.pets(appState: state, reactions: .shared, animating: true)
        let (pets, overflow) = (layout.pets, layout.overflow)
        XCTAssertEqual(pets.count, 2)
        XCTAssertEqual(overflow, 0)
        let claude = try! XCTUnwrap(pets.first { $0.id == BurrowResidents.heroId(agent: "claude") })
        XCTAssertEqual(claude.sessionCount, 3)
        XCTAssertEqual(claude.status, .running, "the pet shows its busiest conversation")
        XCTAssertEqual(claude.state, .busy)
        XCTAssertEqual(pets.map(\.id), [BurrowResidents.heroId(agent: "claude"), BurrowResidents.heroId(agent: "codex")],
                       "agents stand in the order they first started")
    }

    func testTwelveConversationsAreFourPets() {
        let state = AppState()
        var sessions: [String: SessionSnapshot] = [:]
        for (i, source) in ["claude", "codex", "opencode", "google-antigravity"].enumerated() {
            for j in 0..<3 { sessions["\(source)-\(j)"] = session(source, .idle, started: TimeInterval(i * 10 + j)) }
        }
        state.sessions = sessions
        let layout = BurrowResidents.pets(appState: state, reactions: .shared, animating: true)
        let (pets, overflow) = (layout.pets, layout.overflow)
        XCTAssertEqual(pets.count, 4)
        XCTAssertEqual(overflow, 0)
        XCTAssertTrue(pets.allSatisfy { $0.sessionCount == 3 })
    }

    func testWaitingConversationLightsItsAgentsPet() {
        let state = AppState()
        state.sessions = [
            "c1": session("claude", .running, started: 1),
            "c2": session("claude", .waitingApproval, started: 2),
        ]
        let pet = try! XCTUnwrap(BurrowResidents.pets(appState: state, reactions: .shared, animating: true).pets.first)
        XCTAssertEqual(pet.state, .attention)
        XCTAssertTrue(BurrowLipMetrics.isLit(pet.state))
    }

    func testDenKeepsEachAgentsConversationsTogether() {
        let state = AppState()
        state.sessions = [
            "c1": session("claude", .idle, started: 1),
            "x1": session("codex", .idle, started: 2),
            "c2": session("claude", .idle, started: 3),
        ]
        let groups = BurrowResidents.grouped(["c1", "x1", "c2"], appState: state)
        XCTAssertEqual(groups.map(\.agent), ["claude", "codex"])
        XCTAssertEqual(groups.flatMap(\.ids), ["c1", "c2", "x1"])
    }
}
