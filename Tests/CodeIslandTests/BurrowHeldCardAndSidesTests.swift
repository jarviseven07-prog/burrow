import XCTest
import CodeIslandCore
@testable import CodeIsland

/// design/v15 problems 1–4: a lit pet opens its card (hover, click,
/// VoiceOver), pets keep their side past four, and agents without their
/// own pet take no place beside the notch.
@MainActor
final class BurrowHeldCardAndSidesTests: XCTestCase {
    private func pet(_ id: String, _ status: AgentStatus = .running,
                     waiting: String? = nil, question: String? = nil) -> BurrowPeekPet {
        let state = MascotView.petState(status: status, reaction: nil, animating: true)
        return BurrowPeekPet(id: id, source: "claude", status: status, state: state,
                             rows: PeekRows.forSource("claude")!, sessionCount: 1,
                             reactionSessionId: nil, waitingSessionId: waiting, sign: nil,
                             questionSessionId: question)
    }

    // MARK: 1 & 3 — a lit pet's held card

    /// A lit pet holds its approval card back; once the card is up it holds
    /// nothing, and an unlit pet never holds one.
    func testALitPetHoldsItsApproval() {
        let asking = pet("a", .waitingApproval, waiting: "s1")
        XCTAssertEqual(BurrowResidents.heldCard(for: asking, surface: .collapsed), .approval("s1"))
        XCTAssertEqual(BurrowResidents.heldCard(for: asking, surface: .sessionList), .approval("s1"))
        XCTAssertNil(BurrowResidents.heldCard(for: asking, surface: .approvalCard(sessionId: "s1")))
        XCTAssertNil(BurrowResidents.heldCard(for: pet("b", .running), surface: .collapsed))
    }

    /// A pet waiting on a question holds the question card.
    func testALitPetHoldsItsQuestion() {
        let asking = pet("a", .waitingQuestion, question: "s2")
        XCTAssertEqual(BurrowResidents.heldCard(for: asking, surface: .collapsed), .question("s2"))
        XCTAssertNil(BurrowResidents.heldCard(for: asking, surface: .questionCard(sessionId: "s2")))
    }

    /// A click (or VoiceOver's press) opens the hovered lit pet's card
    /// first, then the first lit pet's; nothing when none is lit.
    func testAClickOpensTheHoveredLitPetsCardFirst() {
        let pets = [pet("a", .waitingApproval, waiting: "s1"), pet("b", .running),
                    pet("c", .waitingQuestion, question: "s3")]
        XCTAssertEqual(BurrowResidents.heldCard(pets: pets, preferring: "c", surface: .collapsed), .question("s3"))
        XCTAssertEqual(BurrowResidents.heldCard(pets: pets, preferring: "b", surface: .collapsed), .approval("s1"))
        XCTAssertEqual(BurrowResidents.heldCard(pets: pets, preferring: nil, surface: .collapsed), .approval("s1"))
        XCTAssertNil(BurrowResidents.heldCard(pets: [pet("b")], preferring: "b", surface: .collapsed))
    }

    // VoiceOver's press runs the same `openHeldCard` as a click; SwiftUI
    // builds no accessibility tree for an offscreen window, so the press
    // itself is checked against the running app (design/v15 README).

    /// The hovered pet is forgotten as soon as anything opens over the
    /// burrow or the pointer leaves, so a closed card's pet never opens it
    /// again from a hover elsewhere.
    func testTheHoveredPetIsForgottenWhenTheBurrowCovers() {
        XCTAssertTrue(NotchHoverInteraction.keepsHoveredPet(surface: .collapsed, pointerOnIsland: true))
        XCTAssertFalse(NotchHoverInteraction.keepsHoveredPet(surface: .collapsed, pointerOnIsland: false))
        for surface: IslandSurface in [.sessionList, .approvalCard(sessionId: "s"), .questionCard(sessionId: "s")] {
            XCTAssertFalse(NotchHoverInteraction.keepsHoveredPet(surface: surface, pointerOnIsland: true), "\(surface)")
        }
    }

    // MARK: 2 — pets keep their side

    private func sides(_ layout: BurrowLayout) -> [String: String] {
        var out: [String: String] = [:]
        layout.left.forEach { out[$0.id] = "L" }
        layout.right.forEach { out[$0.id] = "R" }
        return out
    }

    /// Agents by start time 1, 2, 3…, arranged in `priority` order.
    private func arrange(_ memory: BurrowSideMemory, _ ids: [String], urgent: Set<String> = []) -> BurrowLayout {
        let pets = ids.map { urgent.contains($0) ? pet($0, .waitingApproval, waiting: "s-\($0)") : pet($0) }
        let priority = pets.sorted { (urgent.contains($0.id) ? 0 : 1) < (urgent.contains($1.id) ? 0 : 1) }
        return memory.arrange(priority) { p in Date(timeIntervalSince1970: Double(ids.firstIndex(of: p.id)!)) }
    }

    /// A fifth agent arriving — even one that needs you — moves no pet to
    /// the other side, and the island still holds two per side.
    func testAFifthAgentMovesNoPetAcrossTheNotch() {
        let memory = BurrowSideMemory()
        let before = sides(arrange(memory, ["a", "b", "c", "d"]))
        XCTAssertEqual(before, ["a": "L", "b": "R", "c": "L", "d": "R"])
        let five = arrange(memory, ["a", "b", "c", "d", "e"], urgent: ["e"])
        XCTAssertEqual(five.overflow, 1)
        XCTAssertEqual([five.left.count, five.right.count], [2, 2], "two per side: the island keeps its width")
        let after = sides(five)
        XCTAssertNotNil(after["e"], "the pet that needs you shows")
        for (id, side) in after where id != "e" {
            XCTAssertEqual(side, before[id], "\(id) changed sides")
        }
    }

    /// The oldest agent leaving moves nobody: every other pet keeps its
    /// side (it used to shift them all across).
    func testAnAgentLeavingMovesNobody() {
        let memory = BurrowSideMemory()
        let before = sides(arrange(memory, ["a", "b", "c", "d"]))
        let after = sides(arrange(memory, ["b", "c", "d"]))
        for (id, side) in after { XCTAssertEqual(side, before[id], "\(id) changed sides") }
        // A newcomer fills the lighter side.
        XCTAssertEqual(sides(arrange(memory, ["b", "c", "d", "e"]))["e"], "L")
    }

    /// Both pets on one side leaving would leave the island lopsided (and
    /// wider): then, and only then, one pet crosses over — the newest.
    func testOnlyALopsidedBurrowMovesAPet() {
        let memory = BurrowSideMemory()
        _ = arrange(memory, ["a", "b", "c", "d"])            // a c | b d
        let layout = arrange(memory, ["b", "d"])              // left empty
        XCTAssertEqual([layout.left.count, layout.right.count], [1, 1])
        XCTAssertEqual(sides(layout), ["b": "R", "d": "L"], "the newest crossed; b stayed")
    }

    /// However agents come and go, the sides never differ by more than one,
    /// so the island is always as wide as before: 257pt for one or two
    /// pets, 321pt for three or four.
    func testComingAndGoingNeverWidensTheIsland() {
        var rng = SystemRandomNumberGenerator()
        let memory = BurrowSideMemory()
        var home: [String] = []
        var next = 0
        for _ in 0..<400 {
            if home.isEmpty || (home.count < 7 && Bool.random(using: &rng)) {
                home.append("p\(next)"); next += 1
            } else {
                home.remove(at: Int.random(in: 0..<home.count, using: &rng))
            }
            let urgent = Set(home.filter { _ in Int.random(in: 0..<4, using: &rng) == 0 })
            let layout = arrange(memory, home, urgent: urgent)
            XCTAssertLessThanOrEqual(abs(layout.left.count - layout.right.count), 1)
            XCTAssertEqual(layout.left.count + layout.right.count, min(home.count, 4))
            let width = BurrowLipMetrics.width(notchWidth: 185, left: layout.left.count, right: layout.right.count,
                                               hasOverflow: layout.overflow > 0)
            XCTAssertEqual(width, BurrowLipMetrics.width(notchWidth: 185, pets: min(home.count, 4), hasOverflow: layout.overflow > 0))
        }
    }

    /// Up to four, every pet shows, alternating from the oldest.
    func testUpToFourEveryPetShows() {
        let layout = arrange(BurrowSideMemory(), ["b", "c", "a"])
        XCTAssertEqual(layout.overflow, 0)
        XCTAssertEqual(layout.pets.map(\.id), ["b", "c", "a"])
    }

    // MARK: 4 — agents without a pet

    /// The mint fallback Clawd is gone (2026-10-28): an agent without a pet
    /// of its own gets none, so it takes no place beside the notch.
    func testAgentsWithoutTheirOwnPetGetNone() {
        XCTAssertNil(PeekRows.forSource("gemini"))
        XCTAssertNil(PeekRows.forSource("cursor"))
        XCTAssertNil(PetSpecies.of(source: "antigravity"), "the Claude Code fork, not Google's")
        XCTAssertEqual(PetSpecies.of(source: "google-antigravity"), .antigravity)
        XCTAssertEqual(Set(PetSpecies.allCases), Set(PetSpecies.bySource.values), "every pet belongs to an agent")
    }

    /// Claude and unknown agents still use the base sounds.
    func testClaudeAndUnknownAgentsKeepTheBaseVoice() {
        XCTAssertNil(SoundManager.voice(forSource: "claude"))
        XCTAssertNil(SoundManager.voice(forSource: "gemini"))
        XCTAssertEqual(SoundManager.voice(forSource: "codex"), "codex")
    }
}
