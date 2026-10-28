import XCTest
import CodeIslandCore
@testable import CodeIsland

/// The collapsed burrow: whole pets beside the notch, never below the menu bar.
final class BurrowLipMetricsTests: XCTestCase {
    /// Only a pet that needs you is lit.
    func testOnlyAPetThatNeedsYouIsLit() {
        for state in PetState.allCases {
            XCTAssertEqual(BurrowLipMetrics.isLit(state), state == .attention, "\(state)")
        }
    }

    /// Ears are the same on both sides, so the notch stays centred; each pet
    /// is whole, and four still stay close to the notch.
    func testEarsAreSymmetricAndHugTheNotch() {
        let notch: CGFloat = 185
        func width(_ pets: Int) -> CGFloat {
            BurrowLipMetrics.width(notchWidth: notch, pets: pets, hasOverflow: false)
        }
        XCTAssertEqual(width(0), notch)
        XCTAssertEqual(width(1), width(2), "the second pet takes the other side")
        XCTAssertEqual(width(1), notch + 2 * (BurrowLipMetrics.petSlot + BurrowLipMetrics.earPad))
        XCTAssertGreaterThanOrEqual(BurrowLipMetrics.petSlot, CGFloat(PetFrame.canvasWidth) * Burrow.petCell,
                                    "a pet, laptop and all, is never cut off")
        XCTAssertGreaterThan(width(4), width(2))
        XCTAssertLessThanOrEqual(width(4), notch + 2 * 70, "four pets stay close to the notch")
    }

    /// The pet stands inside the menu bar's band: head not cut off at the top,
    /// feet not below the band.
    /// Every band the island can have — a menu bar without a notch (24–25pt),
    /// notches (32–38pt); there is no custom height.
    func testPetsStandInsideTheBand() {
        for band: CGFloat in [24, 25, 32, 37, 38] {
            for species in PetSpecies.allCases {
                let rows = PeekRows(species.sprite)
                let ear = BurrowLipMetrics.earOffset(rows: rows, bandHeight: band)
                XCTAssertGreaterThanOrEqual(ear + CGFloat(rows.bodyTop) * Burrow.petCell, 0, "\(species) in \(band)pt: head above the band")
                XCTAssertLessThanOrEqual(ear + CGFloat(rows.bodyBottom + 1) * Burrow.petCell, band, "\(species) in \(band)pt: feet below the band")
            }
        }
    }

    // MARK: - Signs above the laptop

    /// The collapsed island's width is locked: signs live inside each pet's
    /// own canvas, so working pets take exactly the room idle ones do.
    func testIslandWidthIsLocked() {
        let widths = (1...4).map { BurrowLipMetrics.width(notchWidth: 185, pets: $0, hasOverflow: false) }
        XCTAssertEqual(widths, [257, 257, 321, 321])
        XCTAssertEqual(BurrowLipMetrics.width(notchWidth: 185, pets: 4, hasOverflow: true), 357)
        XCTAssertEqual(BurrowLipMetrics.petSlot, 32)
        XCTAssertGreaterThanOrEqual(BurrowLipMetrics.petSlot, CGFloat(PetFrame.canvasWidth) * Burrow.petCell,
                                    "the whole canvas, sign and all, fits the pet's slot")
    }

    /// The sign is drawn inside the band at every menu bar height: its top
    /// row is not cut off.
    func testSignsSitInsideTheBand() {
        for band: CGFloat in [24, 25, 32, 37, 38] {
            for species in PetSpecies.allCases {
                let rows = PeekRows(species.sprite)
                // PixelPetView: the 28.5pt canvas is centred on the 24pt
                // frame and raised 1.5 cells.
                let canvasTop = BurrowLipMetrics.earOffset(rows: rows, bandHeight: band)
                    + (Burrow.petSize - CGFloat(PetFrame.canvasHeight) * Burrow.petCell) / 2 - 1.5 * Burrow.petCell
                let plain = Set(PetFrame.pixels(sprite: species.sprite, state: .busy, t: 1).map { "\($0.x),\($0.y)" })
                for sign in PetSign.allCases {
                    let added = PetFrame.pixels(sprite: species.sprite, state: .busy, t: 1, sign: sign)
                        .filter { !plain.contains("\($0.x),\($0.y)") }
                    let top = canvasTop + CGFloat(added.map(\.y).min() ?? 0) * Burrow.petCell
                    XCTAssertGreaterThanOrEqual(top, 0, "\(species) \(sign) in \(band)pt: cut off at the top")
                }
            }
        }
    }

    /// Which sign a conversation shows: its tool's kind while running one,
    /// the dots while thinking (or running with no tool known), none while
    /// idle or waiting on you — the "!" and the night light say that.
    func testSignFollowsTheConversation() {
        var s = SessionSnapshot()
        s.status = .running
        for (tool, sign) in [("Bash", PetSign.shell), ("exec_command", .shell), ("Edit", .edit), ("Write", .edit),
                             ("apply_patch", .edit), ("Read", .read), ("Grep", .read), ("WebFetch", .web),
                             ("Agent", .agent), ("mcp__Claude_Browser__navigate", .other)] {
            s.currentTool = tool
            XCTAssertEqual(BurrowPetSign.of(s), sign, tool)
        }
        for label in ["working", "tool", "llm", "reply", "", nil] as [String?] {
            s.currentTool = label
            XCTAssertEqual(BurrowPetSign.of(s), .thinking, label ?? "nil")
        }
        s.status = .processing; s.currentTool = nil
        XCTAssertEqual(BurrowPetSign.of(s), .thinking)
        for status in [AgentStatus.idle, .waitingApproval, .waitingQuestion] {
            s.status = status; s.currentTool = "Bash"
            XCTAssertNil(BurrowPetSign.of(s), "\(status)")
        }
    }

    /// A pet's sign speaks for its most pressing conversation.
    @MainActor
    func testAnAgentsSignFollowsItsMostPressingConversation() {
        let state = AppState()
        var thinking = SessionSnapshot()
        thinking.source = "claude"; thinking.status = .processing
        var editing = SessionSnapshot()
        editing.source = "claude"; editing.status = .running; editing.currentTool = "Edit"
        var asking = SessionSnapshot()
        asking.source = "codex"; asking.status = .waitingApproval; asking.currentTool = "Bash"
        state.sessions = ["a": thinking, "b": editing, "c": asking]
        let pets = BurrowResidents.agents(appState: state, reactions: PetReactionCenter.shared, animating: false)
        func sign(_ agent: String) -> PetSign?? {
            pets.first { $0.id == BurrowResidents.heroId(agent: agent) }.map(\.sign)
        }
        XCTAssertEqual(sign("claude"), .some(.edit), "running outranks thinking")
        XCTAssertEqual(sign("codex"), .some(nil), "waiting on you: the night light, no sign")
    }
}
