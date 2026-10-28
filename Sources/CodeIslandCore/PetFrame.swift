import Foundation

/// The seven buddy states (anthropics/claude-desktop-buddy).
public enum PetState: String, CaseIterable, Sendable {
    case sleep, idle, busy, attention, celebrate, dizzy, heart

    /// How often the frame actually changes — the timeline doesn't need to
    /// tick faster than this.
    public var frameInterval: TimeInterval {
        switch self {
        case .sleep: return 0.2
        case .idle: return 0.1
        // Beats every 0.25s (and the "!" with them): twice that is plenty,
        // and a wait can last minutes.
        case .attention: return 0.125
        // Hearts drift a row every ~0.27s, the hop is 0.5s.
        case .heart: return 0.1
        // Keystrokes (0.09s), confetti, the dizzy stars' orbit.
        case .busy, .celebrate, .dizzy: return 0.05
        }
    }
}

/// A 16x16 pet drawing. Row strings use the legend in design/pets.json.
public struct PetSprite: Sendable {
    public let rows: [[Character]]
    public let palette: [Character: UInt32]
    public let eyeBackground: Character
    /// Set for a pet whose face is a screen (Codex): no E cells, the eyes are
    /// a glyph lit in the palette's E colour (PetFrame.screenGlyph).
    public let screenFace: PetScreenFace?

    public init(rows: [String], palette: [Character: UInt32], eyeBackground: Character, screenFace: PetScreenFace? = nil) {
        self.rows = rows.map(Array.init)
        self.palette = palette
        self.eyeBackground = eyeBackground
        self.screenFace = screenFace
    }
}

/// Where a screen face's glyph starts: the top-left cell of its 8x3 box, in
/// sprite coordinates.
public struct PetScreenFace: Sendable, Equatable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public struct PetPixel: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let rgb: UInt32
}

/// What a busy pet is doing, drawn as a small sign above its laptop — the
/// same pixel language as the sleeping pet's z and the waiting pet's "!".
public enum PetSign: String, CaseIterable, Sendable {
    case shell, edit, read, web, agent, other, thinking

    /// 5x5 at most; "1" in the sign's colour, other keys as `colors`.
    var rows: [String] {
        switch self {
        case .shell: return ["1....", ".1...", "1....", "..111"]
        case .edit: return ["....p", "...yy", "..yy.", ".yy..", "k...."]
        case .read: return [".111.", "1...1", "1...1", ".111.", "....1"]
        case .web: return [".111.", "1.1.1", "11111", "1.1.1", ".111."]
        case .agent: return ["..1..", ".111.", "11111", ".111.", "..1.."]
        case .other: return [".1.1.", ".111.", "..1..", "..1..", "..1.."]
        case .thinking: return ["1.1.1"]
        }
    }

    var colors: [Character: UInt32] {
        switch self {
        case .shell: return ["1": 0x8FCF89]
        // The pencil's tip is light enough to see on the black burrow.
        case .edit: return ["y": 0xFFD84D, "p": 0xFF8FA8, "k": 0x9B958D]
        case .read: return ["1": 0xCDB3FA]
        case .web: return ["1": 0x73D6DB]
        case .agent: return ["1": 0xFA9E7A]
        case .other, .thinking: return ["1": 0xC9C3BA]
        }
    }

    /// The sign's pixels, row by row: `rgb` nil where it is clear. Lets the
    /// den draw the same sign at the start of a conversation's row.
    public var pixelRows: [[UInt32?]] {
        rows.map { row in row.map { colors[$0] } }
    }

    /// Thinking, the dots come one by one: ".", "..", "...".
    static let thinkingDotPeriod = 0.35

    /// Between two tools an agent thinks for a moment; a tool's sign stays
    /// up through it instead of flickering to the dots and back.
    public static func lingers(from old: PetSign?, to new: PetSign?) -> Bool {
        guard let old, old != .thinking else { return false }
        return new == .thinking
    }
}

/// Composes one animation frame: the sprite plus state effects (eyes, bob,
/// particles) on a 20x19 canvas. Pure function of (sprite, state, t) so the
/// view, tests and the design page all agree.
public enum PetFrame {
    public static let canvasWidth = 20
    public static let canvasHeight = 19
    /// Where the 16x16 sprite sits on the canvas; the margins hold particles.
    public static let originX = 2
    public static let originY = 3

    enum EyeMode { case open, closed, happy, lookLeft, lookRight, diagonalA, diagonalB }

    enum Glyph {
        case bigZ, smallZ, bang, heart, star, dot

        var rows: [String] {
            switch self {
            case .bigZ: return ["1111", "..1.", ".1..", "1111"]
            case .smallZ: return ["111", ".1.", "111"]
            case .bang: return ["11", "11", "11", "..", "11"]
            case .heart: return [".1.1.", "11111", ".111.", "..1.."]
            case .star: return [".1.", "111", ".1."]
            case .dot: return ["1"]
            }
        }
    }

    enum FX {
        static let zzz: UInt32 = 0xBFD3FF
        /// A failed turn's dizzy stars: embers, not the gold of a celebration.
        static let star: UInt32 = 0xEF7468
        /// The waiting pet's "!": the night light's amber (Burrow.amber), so
        /// "needs you" is one colour on the notch, in the den and on the card.
        static let alert: UInt32 = 0xF5B764
        static let love: UInt32 = 0xFF6B8B
        static let confetti: [UInt32] = [0xFF6B8B, 0xFFD84D, 0x6BE3B0]
        static let laptopLid: UInt32 = 0xAEB5C2
        static let laptopScreen: UInt32 = 0x0C1520
        static let laptopBase: UInt32 = 0x6F7786
        static let keySpark: UInt32 = 0x9FE8FF
        static let code: [UInt32] = [0x7FD8FF, 0xF5B764, 0x6BE3B0, 0xC9C3BA, 0xFF8FA8]
    }

    struct Overlay {
        let glyph: Glyph
        let x: Int
        let y: Int
        let rgb: UInt32
    }

    struct Pose {
        var eyes: EyeMode = .open
        var dx = 0
        var dy = 0
        var shearTop = 0
        var overlays: [Overlay] = []
        var desk: Desk? = nil
    }

    /// Busy: the pet at a little laptop by its side (design/v08, direction C).
    /// `keyStep` is the current keystroke, nil while it stops to look at the
    /// screen; `line`/`chars` is how far the code on the screen has got.
    struct Desk {
        var keyStep: Int?
        var keyFresh: Bool
        var line: Int
        var chars: Int
    }

    /// Code typed on the busy pet's screen: each line's length and colour
    /// (an index into FX.code). Same lines as design/v08/typing-frames.js.
    static let codeLines: [(length: Int, color: Int)] = [
        (9, 0), (7, 2), (7, 0), (8, 3), (8, 0), (8, 0), (8, 1), (7, 2),
    ]
    static let keyPeriod = 0.09

    /// Where the typing is at `t`: a keystroke every 0.09s, with a break to
    /// look at the screen for the last 0.9s of every 4s.
    static func desk(_ t: Double) -> Desk {
        let t = max(t, 0)
        let typing = t.truncatingRemainder(dividingBy: 4.0) <= 3.1
        // Characters land every 0.075s, then a half-second pause per line.
        // The lines loop as a whole, so the screen never jumps: the line
        // count keeps going from one round to the next.
        let perChar = 0.075, pause = 0.5
        let round = codeLines.reduce(0.0) { $0 + Double($1.length) * perChar + pause }
        let rounds = Int((t / round).rounded(.down))
        var rem = t - Double(rounds) * round, line = rounds * codeLines.count
        while true {
            let n = codeLines[line % codeLines.count].length
            let duration = Double(n) * perChar + pause
            if rem < duration {
                return Desk(
                    keyStep: typing ? step(t, keyPeriod) : nil,
                    keyFresh: frac(t / keyPeriod) < 0.5,
                    line: line,
                    chars: min(n, Int((rem / perChar).rounded(.down)))
                )
            }
            rem -= duration
            line += 1
        }
    }

    /// Idle carousel, one beat every 0.4s (9.6s loop) — like buddy's idle
    /// micro-actions instead of one clip on repeat.
    enum IdleBeat { case rest, blink, left, right, hop }
    static let idleBeats: [IdleBeat] = [
        .rest, .rest, .rest, .rest, .blink, .rest, .rest, .left, .left, .rest, .right, .right,
        .rest, .rest, .blink, .rest, .hop, .rest, .hop, .rest, .rest, .blink, .blink, .rest,
    ]

    static func frac(_ v: Double) -> Double { v - v.rounded(.down) }
    static func step(_ t: Double, _ period: Double) -> Int { Int((max(t, 0) / period).rounded(.down)) }

    static func pose(_ state: PetState, t: Double) -> Pose {
        var p = Pose()
        switch state {
        case .sleep:
            p.eyes = .closed
            p.dy = step(t, 1.2) % 2
            let a = frac(t / 2.4), b = frac(t / 2.4 + 0.5)
            p.overlays = [
                Overlay(glyph: .smallZ, x: 14 + Int(a * 3), y: 5 - Int(a * 5), rgb: FX.zzz),
                Overlay(glyph: .bigZ, x: 16 + Int(b * 2), y: 3 - Int(b * 4), rgb: FX.zzz),
            ]
        case .idle:
            switch idleBeats[step(t, 0.4) % idleBeats.count] {
            case .rest: break
            case .blink: p.eyes = .closed
            case .left: p.eyes = .lookLeft
            case .right: p.eyes = .lookRight
            case .hop: p.dy = -1
            }
        case .busy:
            // Stepped two cells left to make room for the laptop on its right,
            // eyes on the screen while it types.
            let desk = desk(t)
            p.desk = desk
            p.dx = -2
            p.eyes = desk.keyStep == nil ? .open : .lookRight
        case .attention:
            let beat = step(t, 0.25)
            p.dy = -(beat % 2)
            if beat % 4 != 3 {
                p.overlays = [Overlay(glyph: .bang, x: 17, y: 1, rgb: FX.alert)]
            }
        case .celebrate where t >= 0 && t < celebrateAnticipation:
            // Anticipation: a beat crouched with eyes shut before the jump.
            p.eyes = .closed
            p.dy = 1
        case .celebrate:
            p.eyes = .happy
            p.dy = [0, -2, -3, -2][step(t, 0.15) % 4]
            let xs = [1, 3, 16, 18, 0, 19, 5, 14]
            let fall = step(t, 0.125)
            p.overlays = xs.enumerated().map { i, x in
                Overlay(glyph: .dot, x: x, y: (fall + i * 5) % canvasHeight, rgb: FX.confetti[i % 3])
            }
        case .dizzy:
            let beat = step(t, 0.3) % 2
            p.eyes = beat == 0 ? .diagonalA : .diagonalB
            p.shearTop = beat == 0 ? 1 : -1
            p.overlays = (0..<3).map { k in
                let a = t * 2 * .pi / 1.2 + Double(k) * 2 * .pi / 3
                let x = 10 + Int((cos(a) * 7).rounded()) - 1
                let y = 1 + Int((sin(a) * 1.5).rounded()) - 1
                return Overlay(glyph: .star, x: x, y: y, rgb: FX.star)
            }
        case .heart:
            p.eyes = .happy
            p.dy = -(step(t, 0.5) % 2)
            let a = frac(t / 1.6), b = frac(t / 1.6 + 0.5)
            p.overlays = [
                Overlay(glyph: .heart, x: 15, y: 6 - Int(a * 6), rgb: FX.love),
                Overlay(glyph: .heart, x: 0, y: 6 - Int(b * 6), rgb: FX.love),
            ]
        }
        return p
    }

    /// Whether an eye cell stays dark under `mode`. Eyes are 2x2 blocks, or
    /// 1-wide columns (Clawd): `top` = the cell below is also eye, `left` =
    /// the cell right is eye, `wide` = the eye is two cells across. Narrow
    /// eyes can't glance sideways, so they stay open for looks.
    static func keepsEye(_ mode: EyeMode, top: Bool, left: Bool, wide: Bool = true) -> Bool {
        switch mode {
        case .open: return true
        case .closed: return !top
        case .happy: return top
        case .lookLeft: return !wide || left
        case .lookRight: return !wide || !left
        case .diagonalA: return top == left
        case .diagonalB: return top != left
        }
    }

    /// A screen face's eyes, like the official Codex pet's: >_ awake, v v
    /// shut, ^ ^ happy, x x hurt. Looks slide the whole glyph a cell.
    static func screenGlyph(_ mode: EyeMode) -> [String] {
        switch mode {
        case .open, .lookLeft, .lookRight: return ["1.......", ".1......", "1..1111."]
        case .closed: return ["........", "1.1..1.1", ".1....1."]
        case .happy: return [".1....1.", "1.1..1.1", "........"]
        case .diagonalA, .diagonalB: return ["1.1..1.1", ".1....1.", "1.1..1.1"]
        }
    }

    /// While a screen-faced pet works, its cursor `_` blinks: off for every
    /// other half second.
    static let cursorBlinkPeriod = 0.5

    /// How long a celebrating pet crouches before it jumps. Only seen when
    /// `t` is counted from the reaction's start (PixelPetView does that).
    public static let celebrateAnticipation: Double = 0.24

    /// Which way an idle pet looks: -1 left, 0 straight ahead, 1 right.
    /// Applied only while its eyes are open and resting, so blinks and the
    /// idle carousel's own glances still play.
    /// `sign` shows only while the pet works at its laptop (busy).
    public static func pixels(sprite: PetSprite, state: PetState, t: Double, gaze: Int = 0, sign: PetSign? = nil) -> [PetPixel] {
        var pose = pose(state, t: t)
        if state == .idle, gaze != 0, pose.eyes == .open {
            pose.eyes = gaze < 0 ? .lookLeft : .lookRight
        }
        var cells = [[UInt32?]](repeating: [UInt32?](repeating: nil, count: canvasWidth), count: canvasHeight)
        func put(_ x: Int, _ y: Int, _ rgb: UInt32?) {
            guard x >= 0, y >= 0, x < canvasWidth, y < canvasHeight, let rgb else { return }
            cells[y][x] = rgb
        }
        let rows = sprite.rows
        func isEye(_ x: Int, _ y: Int) -> Bool {
            y >= 0 && y < rows.count && x >= 0 && x < rows[y].count && rows[y][x] == "E"
        }

        // Narrow (1-wide) eyes can't drop half an eye to glance, so for a
        // look they slide over by a pixel instead.
        let glanceShift = pose.eyes == .lookLeft ? -1 : pose.eyes == .lookRight ? 1 : 0
        var slidEyes: [(Int, Int)] = []
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." {
                var key = ch
                let wide = isEye(x + 1, y) || isEye(x - 1, y)
                if ch == "E", !keepsEye(pose.eyes, top: isEye(x, y + 1), left: isEye(x + 1, y), wide: wide) {
                    key = sprite.eyeBackground
                    if key == "." { continue }
                } else if ch == "E", !wide, glanceShift != 0 {
                    slidEyes.append((x + glanceShift, y))
                    key = sprite.eyeBackground
                    if key == "." { continue }
                } else if ch == "E", !wide, pose.eyes == .closed {
                    // A narrow eye cut to its bottom row is still a dot; shut,
                    // it widens outward into a dash, "– –".
                    let out = x < row.count / 2 ? x - 1 : x + 1
                    if out >= 0, out < row.count, row[row.index(row.startIndex, offsetBy: out)] != "." {
                        slidEyes.append((out, y))
                    }
                }
                let sx = y < 8 ? pose.shearTop : 0
                put(x + originX + sx + pose.dx, y + originY + pose.dy, sprite.palette[key])
            }
        }
        for (x, y) in slidEyes {
            let sx = y < 8 ? pose.shearTop : 0
            put(x + originX + sx + pose.dx, y + originY + pose.dy, sprite.palette["E"])
        }
        if let face = sprite.screenFace {
            let glyph = screenGlyph(pose.eyes)
            let look = pose.eyes == .lookLeft ? -1 : pose.eyes == .lookRight ? 1 : 0
            let cursorOff = state == .busy && step(t, cursorBlinkPeriod) % 2 == 1
            for (j, row) in glyph.enumerated() {
                for (i, ch) in row.enumerated() where ch == "1" {
                    if cursorOff, j == 2, i >= 3, glyph == screenGlyph(.open) { continue }
                    let y = face.y + j
                    let sx = y < 8 ? pose.shearTop : 0
                    put(face.x + i + look + originX + sx + pose.dx, y + originY + pose.dy, sprite.palette["E"])
                }
            }
        }

        if let desk = pose.desk {
            let floor = sprite.bodyBottom + originY + pose.dy
            // The screen, open toward the pet and seen three-quarters on.
            let sx0 = 15, sx1 = 19, sy0 = floor - 5, sy1 = floor - 1
            for y in sy0...sy1 {
                for x in sx0...sx1 {
                    put(x, y, (y == sy0 || x == sx0 || x == sx1) ? FX.laptopLid : FX.laptopScreen)
                }
            }
            // The last three lines of code, the newest still being typed.
            for r in 0..<3 {
                let line = desk.line - (2 - r)
                guard line >= 0 else { continue }
                let length = line < desk.line ? 3 : min(3, (desk.chars + 1) / 2)
                let rgb = FX.code[codeLines[line % codeLines.count].color]
                for i in 0..<length { put(sx0 + 1 + i, sy0 + 1 + r, rgb) }
            }
            for x in 13...19 { put(x, floor, FX.laptopBase) }
            // The near paw taps the keys; now and then a key sparks.
            let paw = (sprite.palette["B"] ?? 0x888888).darkened(by: 0.28)
            let down = desk.keyStep.map { $0 % 2 == 0 } ?? true
            put(13, floor - (down ? 1 : 2), paw)
            put(14, floor - (down ? 1 : 2), paw)
            if let key = desk.keyStep, key % 4 == 0 {
                put(14, floor - 3 - (desk.keyFresh ? 0 : 1), FX.keySpark)
            }
            // What it is working on, floating above the screen. Never over
            // the pet itself.
            if let sign {
                let top = floor - 12
                var rows = sign.rows
                if sign == .thinking {
                    let dots = step(t, PetSign.thinkingDotPeriod) % 3 + 1
                    rows = rows.map { String($0.prefix(dots * 2 - 1)) }
                }
                let colors = sign.colors
                for (dy, row) in rows.enumerated() {
                    for (dx, ch) in row.enumerated() {
                        guard let rgb = colors[ch] else { continue }
                        let x = 15 + dx, y = top + dy + (sign == .thinking ? 3 : 0)
                        if x < canvasWidth, y >= 0, cells[y][x] == nil { put(x, y, rgb) }
                    }
                }
            }
        }

        for o in pose.overlays {
            for (dy, row) in o.glyph.rows.enumerated() {
                for (dx, ch) in row.enumerated() where ch == "1" {
                    put(o.x + dx, o.y + dy, o.rgb)
                }
            }
        }

        var out: [PetPixel] = []
        for y in 0..<canvasHeight {
            for x in 0..<canvasWidth {
                if let rgb = cells[y][x] { out.append(PetPixel(x: x, y: y, rgb: rgb)) }
            }
        }
        return out
    }
}

// MARK: - Peek metrics

extension PetSprite {
    /// First sprite row with any pixel — the top of the head.
    public var bodyTop: Int {
        rows.firstIndex { $0.contains { $0 != "." } } ?? 0
    }

    /// Last sprite row with any pixel — the feet.
    public var bodyBottom: Int {
        rows.lastIndex { $0.contains { $0 != "." } } ?? rows.count - 1
    }

    /// Last row holding an eye cell (or a screen face's glyph). Peeking out
    /// of the burrow shows the pet down to here, so you can always read its face.
    public var eyeBottom: Int {
        if let face = screenFace { return face.y + 2 }
        return rows.lastIndex { $0.contains("E") } ?? bodyTop + 4
    }
}

extension UInt32 {
    /// This 0xRRGGBB colour with each channel scaled down by `amount`.
    func darkened(by amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            UInt32((Double((self >> shift) & 0xFF) * (1 - amount)).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
}
