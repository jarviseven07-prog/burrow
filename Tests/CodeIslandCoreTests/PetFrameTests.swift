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
                for i in 0..<120 {
                    let px = PetFrame.pixels(sprite: species.sprite, state: state, t: Double(i) * 0.1)
                    XCTAssertFalse(px.isEmpty, "\(species) \(state)")
                    for p in px {
                        XCTAssert((0..<PetFrame.canvasWidth).contains(p.x))
                        XCTAssert((0..<PetFrame.canvasHeight).contains(p.y))
                    }
                }
            }
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
        XCTAssertEqual(eyeRows(.sleep), [11])
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

    /// Busy is typing at a little laptop by its side: the whole pet shows,
    /// the laptop is to its right, its eyes are on the screen, its paw taps,
    /// and code appears on the screen as time goes on.
    func testBusyPetTypesAtALaptopBesideIt() {
        for species in PetSpecies.allCases {
            let sprite = species.sprite
            let body = sprite.palette["B"]!
            let frame = PetFrame.pixels(sprite: sprite, state: .busy, t: 0.02)
            let bodyXs = frame.filter { $0.rgb == body }.map(\.x)
            let lidXs = frame.filter { $0.rgb == 0xAEB5C2 }.map(\.x)
            XCTAssertFalse(lidXs.isEmpty, "\(species): no laptop")
            XCTAssertGreaterThanOrEqual(lidXs.min()!, 15, "\(species): the laptop sits right of the pet")
            // The screen's edge may touch an arm tip, nothing more.
            let resting = PetFrame.pixels(sprite: sprite, state: .idle, t: 0).filter { $0.rgb == body }.count
            XCTAssertGreaterThanOrEqual(bodyXs.count, resting - 4, "\(species): the laptop covers the pet")
            let restingXs = PetFrame.pixels(sprite: sprite, state: .idle, t: 0).filter { $0.rgb == body }.map(\.x)
            XCTAssertEqual(bodyXs.min()!, restingXs.min()! - 2, "\(species): stepped left to make room")

            // The paw goes up and down between keystrokes.
            let paw = body.darkenedForTest(by: 0.28)
            let pawRows = Set([0.02, 0.11].map { t in
                PetFrame.pixels(sprite: sprite, state: .busy, t: t).filter { $0.rgb == paw && $0.x == 13 }.map(\.y)
            })
            XCTAssertEqual(pawRows.count, 2, "\(species): the paw doesn't tap")

            // More code on the screen later on.
            func code(_ t: Double) -> Int {
                PetFrame.pixels(sprite: sprite, state: .busy, t: t)
                    .filter { $0.x >= 16 && $0.x <= 18 && [0x7FD8FF, 0xF5B764, 0x6BE3B0, 0xC9C3BA, 0xFF8FA8].contains($0.rgb) }.count
            }
            XCTAssertGreaterThan(code(2.0), code(0.02), "\(species): nothing gets typed")
        }
    }

    /// Codex's face is a screen (design/v18/v04, after the official Codex
    /// pet): its eyes are a lit glyph — >_ awake, v v asleep, ^ ^ happy,
    /// x x hurt — and while it works the cursor blinks.
    func testCodexScreenFaceChangesWithItsMood() {
        let sprite = PetSpecies.codex.sprite
        let face = try! XCTUnwrap(sprite.screenFace)
        let lit = sprite.palette["E"]!
        func glyph(_ state: PetState, _ t: Double) -> Set<String> {
            Set(PetFrame.pixels(sprite: sprite, state: state, t: t).filter { $0.rgb == lit }.map { "\($0.x),\($0.y)" })
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
        // Working, the cursor _ blinks: four cells fewer every other half second.
        let on = glyph(.busy, 0.1).count, off = glyph(.busy, 0.6).count
        XCTAssertEqual(on - off, 4)
    }

    /// While it types, Clawd's one-pixel eyes slide toward the screen.
    func testTypingPetLooksAtTheScreen() {
        let sprite = PetSpecies.clawd.sprite
        let eye = sprite.palette["E"]!
        func eyeXs(_ t: Double) -> [Int] {
            PetFrame.pixels(sprite: sprite, state: .busy, t: t).filter { $0.rgb == eye }.map(\.x).sorted()
        }
        let typing = eyeXs(0.02), resting = eyeXs(3.5)
        XCTAssertEqual(typing.count, resting.count)
        XCTAssertEqual(zip(typing, resting).map { $0 - $1 }, Array(repeating: 1, count: typing.count),
                       "eyes one pixel to the right while typing")
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

/// A busy pet's sign: what it is working on, above its laptop.
final class PetSignTests: XCTestCase {
    private func cells(_ pixels: [PetPixel]) -> [String: UInt32] {
        Dictionary(uniqueKeysWithValues: pixels.map { ("\($0.x),\($0.y)", $0.rgb) })
    }

    /// The sign sits in the canvas above the screen, right of the pet, and
    /// never paints over the pet, the laptop or anything else in the frame.
    func testSignFloatsAboveTheLaptopAndCoversNothing() {
        for species in PetSpecies.allCases {
            let floor = species.sprite.bodyBottom + PetFrame.originY
            for sign in PetSign.allCases {
                for i in 0..<40 {
                    let t = Double(i) * 0.11
                    let plain = cells(PetFrame.pixels(sprite: species.sprite, state: .busy, t: t))
                    let signed = cells(PetFrame.pixels(sprite: species.sprite, state: .busy, t: t, sign: sign))
                    for (key, rgb) in plain {
                        XCTAssertEqual(signed[key], rgb, "\(species) \(sign): the sign covered \(key)")
                    }
                    let added = signed.keys.filter { plain[$0] == nil }
                    XCTAssertFalse(added.isEmpty, "\(species) \(sign) at \(t): no sign drawn")
                    for key in added {
                        let xy = key.split(separator: ",").compactMap { Int($0) }
                        XCTAssertTrue((15..<PetFrame.canvasWidth).contains(xy[0]), "\(species) \(sign): x \(xy[0])")
                        XCTAssertTrue((0..<(floor - 5)).contains(xy[1]), "\(species) \(sign): y \(xy[1]) not above the screen")
                    }
                }
            }
        }
    }

    /// Only a pet at its laptop wears a sign: asleep, idle, waiting on you
    /// or celebrating, it shows nothing extra.
    func testOnlyABusyPetShowsItsSign() {
        for species in PetSpecies.allCases {
            for state in PetState.allCases where state != .busy {
                XCTAssertEqual(
                    PetFrame.pixels(sprite: species.sprite, state: state, t: 1.3, sign: .shell),
                    PetFrame.pixels(sprite: species.sprite, state: state, t: 1.3),
                    "\(species) \(state)")
            }
        }
    }

    /// Thinking, the dots come one by one and start over.
    func testThinkingDotsComeOneByOne() {
        let sprite = PetSpecies.clawd.sprite
        func dots(_ t: Double) -> Int {
            let plain = Set(PetFrame.pixels(sprite: sprite, state: .busy, t: t).map { "\($0.x),\($0.y)" })
            return PetFrame.pixels(sprite: sprite, state: .busy, t: t, sign: .thinking)
                .filter { !plain.contains("\($0.x),\($0.y)") }.count
        }
        let p = PetSign.thinkingDotPeriod
        XCTAssertEqual([0.1, 1.1, 2.1, 3.1].map { dots($0 * p) }, [1, 2, 3, 1])
    }

    /// A tool's sign holds into the thinking after it; nothing else waits.
    func testOnlyAToolSignLingersIntoThinking() {
        XCTAssertTrue(PetSign.lingers(from: .shell, to: .thinking))
        XCTAssertTrue(PetSign.lingers(from: .edit, to: .thinking))
        XCTAssertFalse(PetSign.lingers(from: .shell, to: .edit))
        XCTAssertFalse(PetSign.lingers(from: .thinking, to: .read))
        XCTAssertFalse(PetSign.lingers(from: nil, to: .thinking))
        XCTAssertFalse(PetSign.lingers(from: .shell, to: nil))
    }
}
