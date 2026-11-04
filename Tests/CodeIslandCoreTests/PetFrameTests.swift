import XCTest
@testable import CodeIslandCore

/// Buddy pixel pets: sprite data integrity and per-state frame composition.
final class PetFrameTests: XCTestCase {
    func testEverySpriteIs16x16AndFullyColored() {
        for species in PetSpecies.allCases {
            let sprite = species.sprite
            XCTAssertEqual(sprite.rows.count, 16, "\(species)")
            for row in sprite.rows {
                XCTAssertEqual(row.count, 16, "\(species)")
                for ch in row where ch != "." {
                    XCTAssertNotNil(sprite.palette[ch], "\(species) has no color for \(ch)")
                }
            }
        }
    }

    func testPetSourcesAreRealAgents() {
        XCTAssertEqual(PetSpecies.bySource["claude"], .clawd)
        XCTAssertEqual(PetSpecies.bySource["codex"], .codex)
        XCTAssertEqual(PetSpecies.bySource["opencode"], .opencode)
        XCTAssertEqual(PetSpecies.bySource["google-antigravity"], .antigravity)
        for source in PetSpecies.bySource.keys {
            XCTAssert(SessionSnapshot.supportedSources.contains(source), "unknown source \(source)")
        }
    }

    func testEveryStateRendersInsideTheCanvasOverALoop() {
        for species in PetSpecies.allCases {
            for state in PetState.allCases {
                for work in [nil] + PetWork.allCases.map(Optional.some) {
                    for i in 0..<120 {
                        let px = PetFrame.pixels(sprite: species.sprite, state: state, t: Double(i) * 0.1, work: work)
                        XCTAssertFalse(px.isEmpty, "\(species) \(state)")
                        for p in px {
                            XCTAssert((0..<PetFrame.canvasWidth).contains(p.x))
                            XCTAssert((0..<PetFrame.canvasHeight).contains(p.y))
                        }
                    }
                }
            }
        }
    }

    /// The waist — the row a squash drops and a stretch repeats — is a plain
    /// body row under the face, so the face always moves as one.
    func testTheWaistIsUnderTheFace() {
        for species in PetSpecies.allCases {
            let sprite = species.sprite
            XCTAssertGreaterThan(sprite.waist, sprite.eyeBottom, "\(species)")
            XCTAssertLessThan(sprite.waist, sprite.bodyBottom, "\(species)")
        }
    }

    func testSleepClosesEyesAndHappyKeepsTopRow() {
        let sprite = PetSpecies.clawd.sprite
        let eye: UInt32 = 0x000000
        // Clawd eyes sit at sprite rows 7-8 → canvas rows 10-11 (originY 3).
        func eyeRows(_ state: PetState, t: Double = 0) -> Set<Int> {
            Set(PetFrame.pixels(sprite: sprite, state: state, t: t)
                .filter { $0.rgb == eye && (6...12).contains($0.y) && [6, 13].contains($0.x) }
                .map(\.y))
        }
        XCTAssertEqual(eyeRows(.idle), [10, 11])
        // Asleep, the top half sinks a row on the out-breath.
        XCTAssertEqual(eyeRows(.sleep), [12])
        XCTAssertEqual(eyeRows(.sleep, t: 1.3), [11])
        XCTAssertEqual(eyeRows(.heart), [10])
    }

    func testAnimationActuallyChangesFrames() {
        let sprite = PetSpecies.clawd.sprite
        for state in PetState.allCases {
            let frames = Set((0..<60).map { i in
                PetFrame.pixels(sprite: sprite, state: state, t: Double(i) * 0.1).map { "\($0.x),\($0.y),\($0.rgb)" }.joined(separator: ";")
            })
            XCTAssertGreaterThan(frames.count, 1, "\(state) never moves")
        }
        for work in PetWork.allCases {
            let frames = Set((0..<60).map { i in
                PetFrame.pixels(sprite: sprite, state: .busy, t: Double(i) * 0.1, work: work).map { "\($0.x),\($0.y),\($0.rgb)" }.joined(separator: ";")
            })
            XCTAssertGreaterThan(frames.count, 1, "\(work) never moves")
        }
    }
}

/// Little life: idle pets glance toward the pointer, and a celebration
/// starts with a crouch.
final class PetLifeTests: XCTestCase {
    private func eyeColumns(_ species: PetSpecies, gaze: Int) -> Set<Int> {
        let eye = species.sprite.palette["E"]!
        // Only the rows the eyes are on: some pets reuse the eye colour
        // elsewhere (Codex's terminal belly).
        let eyeRows = Set((species.sprite.screenFace.map { Array($0.y...($0.y + 2)) }
            ?? species.sprite.rows.indices.filter { species.sprite.rows[$0].contains("E") })
            .map { $0 + PetFrame.originY })
        // t = 0 is a "rest" beat of the idle carousel: eyes open.
        return Set(PetFrame.pixels(sprite: species.sprite, state: .idle, t: 0, gaze: gaze)
            .filter { $0.rgb == eye && eyeRows.contains($0.y) }.map(\.x))
    }

    func testIdlePetsLookTowardThePointer() {
        for species in PetSpecies.allCases {
            let ahead = eyeColumns(species, gaze: 0)
            let left = eyeColumns(species, gaze: -1)
            let right = eyeColumns(species, gaze: 1)
            XCTAssertNotEqual(left, ahead, "\(species) doesn't glance left")
            XCTAssertNotEqual(right, ahead, "\(species) doesn't glance right")
            XCTAssertLessThan(left.min()!, right.max()!, "\(species) looks the wrong way")
        }
    }

    func testCelebrationStartsWithACrouch() {
        let sprite = PetSpecies.clawd.sprite
        let crouch = PetFrame.pixels(sprite: sprite, state: .celebrate, t: 0.05)
        let jump = PetFrame.pixels(sprite: sprite, state: .celebrate, t: PetFrame.celebrateAnticipation + 0.2)
        let top: ([PetPixel]) -> Int = { px in px.filter { $0.rgb == 0xDE886D }.map(\.y).min()! }
        XCTAssertGreaterThan(top(crouch), top(jump), "the crouch should sit lower than the jump")
    }

    /// Clawd's eyes are one pixel wide: shut, they must read as shut — a
    /// dash, not the same dot half as tall.
    func testNarrowEyesShutIntoADash() {
        let sprite = PetSpecies.clawd.sprite
        let eye = sprite.palette["E"]!
        func eyeRuns(_ state: PetState, _ t: Double) -> [Int: [Int]] {
            Dictionary(grouping: PetFrame.pixels(sprite: sprite, state: state, t: t).filter { $0.rgb == eye }, by: \.y)
                .mapValues { $0.map(\.x).sorted() }
        }
        let shut = eyeRuns(.celebrate, 0.05)
        XCTAssertEqual(shut.count, 1, "shut eyes are a single row")
        let xs = shut.values.first!
        XCTAssertEqual(xs.count, 4, "two 2-pixel dashes")
        XCTAssertEqual(Set(xs.map { $0 < 8 }).count, 2, "one dash per eye")
    }

    /// Busy, the pet steps two cells aside and works at its craft on the
    /// right: every craft reads differently, and none covers the pet's face.
    func testEachCraftIsItsOwnAndBesideThePet() {
        for species in PetSpecies.allCases {
            let sprite = species.sprite
            let body = sprite.palette["B"]!
            let restingXs = PetFrame.pixels(sprite: sprite, state: .idle, t: 0).filter { $0.rgb == body }.map(\.x)
            var loops = Set<String>()
            for work in PetWork.allCases {
                let loop = (0..<48).map { i in
                    PetFrame.pixels(sprite: sprite, state: .busy, t: Double(i) * 0.1, work: work)
                        .map { "\($0.x),\($0.y),\($0.rgb)" }.joined(separator: ";")
                }.joined(separator: "|")
                loops.insert(loop)
                // Digging leans in from the waist; the rest stand straight.
                guard work != .search else { continue }
                let bodyXs = PetFrame.pixels(sprite: sprite, state: .busy, t: 0.1, work: work).filter { $0.rgb == body }.map(\.x)
                XCTAssertEqual(bodyXs.min(), restingXs.min()! - 2, "\(species) \(work): stepped aside to make room")
            }
            XCTAssertEqual(loops.count, PetWork.allCases.count, "\(species): two crafts look the same")
        }
    }

    /// The firefly drifts round its head and its eyes follow it.
    func testThinkingEyesFollowTheFirefly() {
        let sprite = PetSpecies.clawd.sprite
        let eye = sprite.palette["E"]!
        func eyeXs(_ t: Double) -> Int {
            PetFrame.pixels(sprite: sprite, state: .busy, t: t, work: .think).filter { $0.rgb == eye }.map(\.x).reduce(0, +)
        }
        // A quarter of the way round it is on the right, three quarters on the left.
        XCTAssertGreaterThan(eyeXs(1.2), eyeXs(3.6))
        let top = sprite.bodyTop + PetFrame.originY
        let above = PetFrame.pixels(sprite: sprite, state: .busy, t: 0, work: .think).filter { $0.y < top }
        XCTAssertFalse(above.isEmpty, "the firefly flies above its head")
    }

    /// Building, the wall goes up a brick at a time and starts over.
    func testEditingBuildsAWallBrickByBrick() {
        let sprite = PetSpecies.clawd.sprite
        func bricks(_ t: Double) -> Int {
            PetFrame.pixels(sprite: sprite, state: .busy, t: t, work: .edit)
                .filter { [0xFFD84D, 0xC9A23A].contains($0.rgb) }.count
        }
        // Late in each beat the carried brick is down: only the wall shows.
        XCTAssertEqual([0.65, 0.7 + 0.65, 0.7 * 3 + 0.65, 0.7 * 6 + 0.65].map(bricks), [0, 2, 6, 0])
    }

    /// The machine's lamp is dark until the lever is pulled, then green.
    func testRunningACommandLightsTheLamp() {
        let sprite = PetSpecies.clawd.sprite
        func has(_ rgb: UInt32, _ t: Double) -> Bool {
            PetFrame.pixels(sprite: sprite, state: .busy, t: t, work: .shell).contains { $0.rgb == rgb }
        }
        XCTAssertTrue(has(0x2E4A2C, 0.2), "the lamp is off before the pull")
        XCTAssertTrue(has(0x8FCF89, 0.6), "the lamp is on after the pull")
        XCTAssertFalse(has(0x2E4A2C, 0.6))
    }

    /// Codex's face is a screen (design/v18/v04, after the official Codex
    /// pet): its eyes are a lit glyph — >_ awake, v v asleep, ^ ^ happy,
    /// x x hurt — and reading, the >_ drops a row to look down.
    func testCodexScreenFaceChangesWithItsMood() {
        let sprite = PetSpecies.codex.sprite
        let face = try! XCTUnwrap(sprite.screenFace)
        let lit = sprite.palette["E"]!
        func glyph(_ state: PetState, _ t: Double, work: PetWork? = nil) -> Set<String> {
            Set(PetFrame.pixels(sprite: sprite, state: state, t: t, work: work).filter { $0.rgb == lit }.map { "\($0.x),\($0.y)" })
        }
        let awake = glyph(.idle, 0), asleep = glyph(.sleep, 0), happy = glyph(.heart, 0.6), hurt = glyph(.dizzy, 0.1)
        XCTAssertEqual(Set([awake, asleep, happy, hurt]).count, 4, "every mood reads differently")
        XCTAssertFalse(sprite.rows.joined().contains("E"), "no eye cells: the screen draws the eyes")
        // The glyph stays on the screen.
        let screen = sprite.palette["S"]!
        let plain = Set(PetFrame.pixels(sprite: PetSprite(rows: sprite.rows.map { String($0) }, palette: sprite.palette,
                                                          eyeBackground: sprite.eyeBackground), state: .idle, t: 0)
            .filter { $0.rgb == screen }.map { "\($0.x),\($0.y)" })
        XCTAssertTrue(awake.isSubset(of: plain), "the >_ is drawn on the screen")
        XCTAssertEqual(face.y + 2, sprite.eyeBottom)
        // Reading, the whole >_ sits a row lower than while it builds.
        func rows(_ cells: Set<String>) -> [Int] { cells.compactMap { Int($0.split(separator: ",")[1]) } }
        let reading = glyph(.busy, 0.1, work: .read), building = glyph(.busy, 0.1, work: .edit)
        XCTAssertEqual(reading.count, building.count)
        XCTAssertEqual(rows(reading).min()!, rows(building).min()! + 1)
    }

    /// At its craft, Clawd's one-pixel eyes slide toward the work on its
    /// right; reading, they look down at the book instead.
    func testWorkingPetLooksAtItsCraft() {
        let sprite = PetSpecies.clawd.sprite
        let eye = sprite.palette["E"]!
        func eyes(_ work: PetWork) -> [PetPixel] {
            PetFrame.pixels(sprite: sprite, state: .busy, t: 0.1, work: work).filter { $0.rgb == eye }
        }
        let building = eyes(.edit), reading = eyes(.read)
        XCTAssertEqual(Set(building.map(\.x)), Set(reading.map { $0.x + 1 }), "eyes one pixel to the right")
        XCTAssertEqual(Set(reading.map(\.y)).count, 1, "reading, only the eyes' lower half shows")
        XCTAssertEqual(Set(building.map(\.y)).count, 2)
    }
}

private extension UInt32 {
    func darkenedForTest(by amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            UInt32((Double((self >> shift) & 0xFF) * (1 - amount)).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
}

/// What a busy pet acts out, and the two ways a pet waits on you.
final class PetWorkTests: XCTestCase {
    /// Only a busy pet acts out its work: asleep, idle, waiting on you or
    /// celebrating, a craft changes nothing.
    func testOnlyABusyPetActsOutItsWork() {
        for species in PetSpecies.allCases {
            for state in PetState.allCases where state != .busy {
                XCTAssertEqual(
                    PetFrame.pixels(sprite: species.sprite, state: state, t: 1.3, work: .shell),
                    PetFrame.pixels(sprite: species.sprite, state: state, t: 1.3),
                    "\(species) \(state)")
            }
        }
    }

    /// With nothing known about its work, a busy pet thinks: the firefly.
    func testABusyPetWithoutWorkThinks() {
        for species in PetSpecies.allCases {
            for t in [0.0, 1.3, 3.7] {
                XCTAssertEqual(PetFrame.pixels(sprite: species.sprite, state: .busy, t: t),
                               PetFrame.pixels(sprite: species.sprite, state: .busy, t: t, work: .think), "\(species)")
            }
        }
    }

    /// An approval stands tall under a "!"; a question tilts its head under
    /// a "?". Both in the night light's amber.
    func testApprovalAndQuestionLookDifferent() {
        for species in PetSpecies.allCases {
            let sprite = species.sprite
            let body = sprite.palette["B"]!
            func top(_ px: [PetPixel]) -> Int { px.filter { $0.rgb == body }.map(\.y).min()! }
            let resting = PetFrame.pixels(sprite: sprite, state: .idle, t: 0)
            let approval = PetFrame.pixels(sprite: sprite, state: .attention, t: 0)
            let question = PetFrame.pixels(sprite: sprite, state: .question, t: 0)
            XCTAssertNotEqual(approval, question, "\(species)")
            XCTAssertEqual(top(approval), top(resting) - 1, "\(species): the sentry stands a row taller")
            XCTAssertTrue(approval.contains { $0.rgb == 0xF5B764 })
            XCTAssertTrue(question.contains { $0.rgb == 0xF5B764 })
            // The head tilts one way, then the other.
            XCTAssertNotEqual(question.filter { $0.rgb != 0xF5B764 },
                              PetFrame.pixels(sprite: sprite, state: .question, t: 1.3).filter { $0.rgb != 0xF5B764 },
                              "\(species): the head doesn't tilt")
        }
    }

    /// A tool's craft holds into the thinking after it; nothing else waits.
    func testOnlyAToolsCraftLingersIntoThinking() {
        XCTAssertTrue(PetWork.lingers(from: .shell, to: .think))
        XCTAssertTrue(PetWork.lingers(from: .search, to: .think))
        XCTAssertFalse(PetWork.lingers(from: .shell, to: .edit))
        XCTAssertFalse(PetWork.lingers(from: .think, to: .read))
        XCTAssertFalse(PetWork.lingers(from: nil, to: .think))
        XCTAssertFalse(PetWork.lingers(from: .shell, to: nil))
    }
}
