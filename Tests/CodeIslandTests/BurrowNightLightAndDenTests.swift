import XCTest
import CodeIslandCore
@testable import CodeIsland

/// design/v19: the night light on a lit floor, embers for failed turns, the
/// pets' own numbers, the one-line den and the approval card's red words.
@MainActor
final class BurrowNightLightAndDenTests: XCTestCase {
    /// The lit floor is right under the pet's feet and inside the menu
    /// bar's band, so the island's edge never cuts the light.
    func testTheLitFloorStaysInsideTheBand() {
        let cell = Burrow.petCell
        for band: CGFloat in [24, 25, 32, 37, 38] {
            for species in PetSpecies.allCases {
                let rows = PeekRows(species.sprite)
                let feet = BurrowLipMetrics.earOffset(rows: rows, bandHeight: band) + CGFloat(rows.bodyBottom + 1) * cell
                let floorBottom = feet + cell
                XCTAssertLessThanOrEqual(floorBottom, band, "\(species) in \(band)pt")
                XCTAssertGreaterThanOrEqual(feet - BurrowNightLight.glowCells * cell, -4.5 * cell, "\(species) in \(band)pt: glow stays near the pet")
            }
        }
    }

    func testTheFloorFadesAtBothEndsAndIsSymmetric() {
        let n = BurrowNightLight.floorCells
        for i in 0..<n {
            XCTAssertEqual(BurrowNightLight.floorAlpha(i), BurrowNightLight.floorAlpha(n - 1 - i), "\(i)")
        }
        XCTAssertEqual(BurrowNightLight.floorAlpha(n / 2), 1)
        XCTAssertLessThan(BurrowNightLight.floorAlpha(0), 0.5)
    }

    /// "Needs you" is one colour: the waiting pet's "!" is the night light's amber.
    func testTheWaitingBangIsAmber() {
        let px = PetFrame.pixels(sprite: PetSpecies.clawd.sprite, state: .attention, t: 0)
        XCTAssertTrue(px.contains { $0.rgb == 0xF5B764 })
        XCTAssertFalse(px.contains { $0.rgb == 0xFF4A3D })
    }

    /// A failed turn's stars are embers, not a celebration's gold.
    func testDizzyStarsAreEmbers() {
        let px = PetFrame.pixels(sprite: PetSpecies.clawd.sprite, state: .dizzy, t: 0)
        XCTAssertTrue(px.contains { $0.rgb == 0xEF7468 })
        XCTAssertFalse(px.contains { $0.rgb == 0xFFE066 })
    }

    // MARK: Embers

    private func failed(at date: Date) -> SessionSnapshot {
        var s = SessionSnapshot()
        s.status = .idle
        s.lastTurnFailed = true
        s.lastActivity = date
        return s
    }

    func testAnEmberStaysUntilTheDenHasBeenOpened() {
        let failure = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(BurrowEmber.isUnseen(failed(at: failure), denSeenAt: .distantPast))
        XCTAssertTrue(BurrowEmber.isUnseen(failed(at: failure), denSeenAt: failure.addingTimeInterval(-1)))
        XCTAssertFalse(BurrowEmber.isUnseen(failed(at: failure), denSeenAt: failure.addingTimeInterval(1)))
        var working = failed(at: failure)
        working.status = .running
        XCTAssertFalse(BurrowEmber.isUnseen(working, denSeenAt: .distantPast), "a new turn is under way")
        var fine = failed(at: failure)
        fine.lastTurnFailed = false
        XCTAssertFalse(BurrowEmber.isUnseen(fine, denSeenAt: .distantPast))
    }

    func testOnlyARestingPetWearsTheEmber() {
        for state in PetState.allCases {
            XCTAssertEqual(BurrowEmber.shows(on: state), state == .idle || state == .sleep, "\(state)")
        }
    }

    func testOpeningTheDenMarksFailuresSeen() {
        let app = AppState()
        XCTAssertEqual(app.denSeenAt, .distantPast)
        app.surface = .sessionList
        let opened = app.denSeenAt
        XCTAssertGreaterThan(opened, .distantPast)
        app.surface = .collapsed
        XCTAssertGreaterThanOrEqual(app.denSeenAt, opened, "leaving the den is a look too")
    }

    // MARK: Numbers

    func testEveryDigitIsThreeByFive() {
        for ch in "0123456789" {
            let rows = BurrowCountBadge.digits[ch]
            XCTAssertEqual(rows?.count, 5, "\(ch)")
            XCTAssertTrue(rows?.allSatisfy { $0.count == 3 } == true, "\(ch)")
        }
        XCTAssertEqual(Set("0123456789".compactMap { BurrowCountBadge.digits[$0] }).count, 10, "no two digits alike")
    }

    func testAPetsInkIsItsOwnColour() {
        XCTAssertEqual(PetSpecies.clawd.ink, [0xDE886D])
        XCTAssertEqual(PetSpecies.codex.ink, [PetSpecies.codex.sprite.palette["B"]!])
        XCTAssertEqual(PetSpecies.antigravity.ink.count, 5, "the arch's bands, top to bottom")
    }

    // MARK: Den

    func testRowsShowATimeOnlyWhereItTellsYouSomething() {
        let now = Date(timeIntervalSince1970: 10_000)
        let earlier = now.addingTimeInterval(-180)
        XCTAssertNil(BurrowTime.row(.working, since: earlier, now: now))
        XCTAssertNil(BurrowTime.row(.thinking, since: earlier, now: now))
        for status: SessionCardStatus in [.needsYou, .done, .idle, .stopped, .error] {
            XCTAssertNotNil(BurrowTime.row(status, since: earlier, now: now), "\(status)")
        }
        XCTAssertNotEqual(BurrowTime.row(.needsYou, since: earlier, now: now), BurrowTime.row(.idle, since: earlier, now: now),
                          "waiting and resting read differently")
    }

    func testTheDenIsNoTallerThanItsRows() {
        XCTAssertEqual(BurrowDenMetrics.blockHeight(rows: 1), BurrowDenMetrics.petBlockHeight + 2 * BurrowDenMetrics.blockPadding,
                       "one conversation still leaves room for the pet and its name")
        XCTAssertEqual(BurrowDenMetrics.blockHeight(rows: 3), 3 * BurrowDenMetrics.rowHeight + 2 * BurrowDenMetrics.blockPadding)
        // As many conversations as the den shows before it scrolls fit,
        // however they are grouped by agent (design/v20: two lines each).
        let shown = SettingsDefaults.maxVisibleSessions, cap = CGFloat(shown) * 54
        XCTAssertLessThanOrEqual(BurrowDenMetrics.height(rows: Array(repeating: 1, count: shown)), cap)
        XCTAssertLessThanOrEqual(BurrowDenMetrics.height(rows: [shown]), cap)
        XCTAssertLessThanOrEqual(BurrowDenMetrics.height(rows: [2, shown - 2]), cap)
    }

    func testTheRowSignSaysOneThing() {
        XCTAssertEqual(BurrowRowSign.Kind(status: .needsYou, sign: nil), .lamp)
        XCTAssertEqual(BurrowRowSign.Kind(status: .error, sign: nil), .ember)
        XCTAssertEqual(BurrowRowSign.Kind(status: .working, sign: .shell), .sign(.shell))
        XCTAssertEqual(BurrowRowSign.Kind(status: .done, sign: nil), .none)
    }

    func testTheAgentNameFitsUnderItsPet() {
        XCTAssertEqual(BurrowAgentName.short("Google Antigravity"), "Antigravity")
        XCTAssertEqual(BurrowAgentName.short("Claude"), "Claude")
    }

    /// design/v20: in everyday words, the command itself in the tooltip.
    func testAWaitingRowSaysWhatTheCommandDoes() {
        let saved = L10n.shared.language
        L10n.shared.language = "zh"
        defer { L10n.shared.language = saved }
        var s = SessionSnapshot()
        s.status = .waitingApproval
        let line = BurrowActivity.line(for: s, pendingTool: "Bash", pendingInput: ["command": "rm -rf build"])
        XCTAssertEqual(line, BurrowActivity.Line(text: "想删掉 build", raw: "rm -rf build"))
        let odd = BurrowActivity.line(for: s, pendingTool: "Bash", pendingInput: ["command": "cd build"])
        XCTAssertEqual(odd, BurrowActivity.Line(text: "cd build", command: true), "nothing to say: the command itself")
    }

    func testAWorkingRowDoesNotRepeatTheToolItsSignShows() {
        var s = SessionSnapshot()
        s.status = .running
        s.currentTool = "Bash"
        s.toolDescription = "Run the tests"
        XCTAssertEqual(BurrowActivity.line(for: s, pendingTool: nil, pendingInput: nil).text, "Run the tests")
    }

    /// design/v20: a Codex turn spends minutes reasoning between steps; its
    /// own note says what it is about to do.
    func testAThinkingCodexRowSaysItsOwnNote() {
        var s = SessionSnapshot()
        s.source = "codex"
        s.status = .processing
        XCTAssertEqual(BurrowActivity.line(for: s, pendingTool: nil, pendingInput: nil).text, L10n.shared["burrow_what_thinking"])
        s.liveCodexOutput = "我会再核对小窝的已读范围。"
        XCTAssertEqual(BurrowActivity.line(for: s, pendingTool: nil, pendingInput: nil).text, "我会再核对小窝的已读范围。")
    }

    /// design/v20 review: two rows alike are told apart by their project.
    func testARowsTooltipNamesItsProject() {
        var s = SessionSnapshot()
        s.cwd = FileManager.default.homeDirectoryForCurrentUser.path + "/Developer/projects/CodeIsland"
        s.lastUserPrompt = "看看刘海"
        let name = s.burrowName
        XCTAssertEqual(BurrowActivity.help(for: s, line: BurrowActivity.Line(text: "在想…")),
                       "\(name)\n~/Developer/projects/CodeIsland\n看看刘海")
        XCTAssertEqual(BurrowActivity.help(for: s, line: BurrowActivity.Line(text: "想删掉 build", raw: "rm -rf build")),
                       "\(name)\n~/Developer/projects/CodeIsland\nrm -rf build")
    }

    // MARK: Approval card

    func testOnlyShellToolsHaveACommand() {
        XCTAssertEqual(BurrowApprovalDanger.command(tool: "Bash", toolInput: ["command": "ls"]), "ls")
        XCTAssertNil(BurrowApprovalDanger.command(tool: "Edit", toolInput: ["command": "ls"]))
        XCTAssertEqual(BurrowApprovalDanger.matches(tool: "Bash", toolInput: ["command": "rm -rf x"]).map(\.kind), [.remove])
    }

    func testEveryDangerHasAReasonInEveryLanguage() {
        for kind in DangerousCommand.Kind.allCases {
            for (lang, table) in L10n.strings {
                XCTAssertNotNil(table["danger_" + kind.rawValue], "\(lang) danger_\(kind.rawValue)")
            }
        }
    }
}
