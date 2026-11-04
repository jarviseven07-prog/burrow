import Foundation

/// The pet's states: buddy's seven (anthropics/claude-desktop-buddy) plus
/// `question` (design/v25: a question to answer is not an approval).
public enum PetState: String, CaseIterable, Sendable {
    case sleep, idle, busy, attention, question, celebrate, dizzy, heart

    /// How often the frame actually changes — the timeline doesn't need to
    /// tick faster than this.
    public var frameInterval: TimeInterval {
        switch self {
        case .sleep: return 0.2
        // The idle carousel's beats are 0.4s; a groom rubs every 0.1s.
        case .idle: return 0.1
        // The "!" / "?" blink every 0.25s: twice that is plenty, and a wait
        // can last minutes.
        case .attention, .question: return 0.125
        // Hearts drift a row every ~0.27s, the hop is 0.5s.
        case .heart: return 0.1
        // Work (a scrape every 0.12s, a firefly's glow), confetti, the
        // dizzy stars' orbit.
        case .busy, .celebrate, .dizzy: return 0.05
        }
    }
}

/// What a busy pet acts out (design/v25, Jarvis picked B "burrow crafts"):
/// each kind of work is a craft of the burrow with a small prop of its own,
/// so it reads without a sign.
public enum PetWork: String, CaseIterable, Sendable {
    /// Between tools — 78% of a busy pet's time (design/v25/README.md).
    case think
    case read, search, edit, shell, web, agent, other, compact

    /// Tools come and go in under a second; the tool's motion stays up
    /// through the moment of thinking after it instead of flickering.
    public static func lingers(from old: PetWork?, to new: PetWork?) -> Bool {
        guard let old, old != .think else { return false }
        return new == .think
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
    /// A plain row under the face: a squash drops it, a stretch repeats it,
    /// a lean bends above it — the face always moves as one.
    public let waist: Int

    public init(rows: [String], palette: [Character: UInt32], eyeBackground: Character,
                screenFace: PetScreenFace? = nil, waist: Int? = nil) {
        let grid = rows.map(Array.init)
        self.rows = grid
        self.palette = palette
        self.eyeBackground = eyeBackground
        self.screenFace = screenFace
        let filled = grid.indices.filter { grid[$0].contains { $0 != "." } }
        self.waist = waist ?? max(filled.first ?? 0, (filled.last ?? 15) - 3)
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

/// What a conversation is working on, as the small sign at the start of its
/// row in the den. (Beside the notch the pet acts it out instead: PetWork.)
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

    /// The sign's pixels, row by row: `rgb` nil where it is clear.
    public var pixelRows: [[UInt32?]] {
        rows.map { row in row.map { colors[$0] } }
    }
}

/// Composes one animation frame: the sprite plus state effects (eyes, bob,
/// props, particles) on a 20x19 canvas. Pure function of (sprite, state,
/// work, t) so the view, tests and the design page all agree — design/v25's
/// prototype (design/v25/候选/motion.py) draws the same pixels.
public enum PetFrame {
    public static let canvasWidth = 20
    public static let canvasHeight = 19
    /// Where the 16x16 sprite sits on the canvas; the margins hold props and
    /// particles.
    public static let originX = 2
    public static let originY = 3

    enum EyeMode { case open, closed, happy, lookLeft, lookRight, down, diagonalA, diagonalB }

    enum Glyph {
        case bigZ, smallZ, bang, question, heart, star, dot

        var rows: [String] {
            switch self {
            case .bigZ: return ["1111", "..1.", ".1..", "1111"]
            case .smallZ: return ["111", ".1.", "111"]
            case .bang: return ["11", "11", "11", "..", "11"]
            case .question: return ["111", "..1", ".11", "...", ".1."]
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
        /// The waiting pet's "!" and "?": the night light's amber
        /// (Burrow.amber), so "needs you" is one colour on the notch, in the
        /// den and on the card.
        static let alert: UInt32 = 0xF5B764
        static let love: UInt32 = 0xFF6B8B
        static let confetti: [UInt32] = [0xFF6B8B, 0xFFD84D, 0x6BE3B0]
        static let code: [UInt32] = [0x7FD8FF, 0xF5B764, 0x6BE3B0, 0xC9C3BA, 0xFF8FA8]
        // Props (design/v25 B). Tool colours are the den signs' own.
        static let metalLight: UInt32 = 0xAEB5C2
        static let metalDark: UInt32 = 0x6F7786
        static let steel: UInt32 = 0x9B958D
        static let white: UInt32 = 0xF3EEE6
        static let grey: UInt32 = 0xC9C3BA
        static let shell: UInt32 = 0x8FCF89
        static let lampOff: UInt32 = 0x2E4A2C
        static let edit: UInt32 = 0xFFD84D
        static let editDark: UInt32 = 0xC9A23A
        static let readDark: UInt32 = 0x8E7BC4
        static let web: UInt32 = 0x73D6DB
        static let earth: UInt32 = 0xA27C58
        static let earthDark: UInt32 = 0x6E553D
        static let firefly: UInt32 = 0xFFE9A8
        static let fireflyDim: UInt32 = 0x7A6C48
    }

    struct Overlay {
        let glyph: Glyph
        let x: Int
        let y: Int
        let rgb: UInt32
    }

    /// The canvas a pose's props draw on.
    struct Canvas {
        var cells: [[UInt32?]]
        let sprite: PetSprite
        /// The canvas row of the pet's feet.
        let floor: Int

        init(sprite: PetSprite, floor: Int) {
            cells = [[UInt32?]](repeating: [UInt32?](repeating: nil, count: canvasWidth), count: canvasHeight)
            self.sprite = sprite
            self.floor = floor
        }

        var paw: UInt32 { (sprite.palette["B"] ?? 0x888888).darkened(by: 0.28) }

        mutating func put(_ x: Int, _ y: Int, _ rgb: UInt32?) {
            guard x >= 0, y >= 0, x < canvasWidth, y < canvasHeight, let rgb else { return }
            cells[y][x] = rgb
        }

        /// Only where nothing is drawn yet: behind what is there.
        mutating func putBehind(_ x: Int, _ y: Int, _ rgb: UInt32) {
            guard x >= 0, y >= 0, x < canvasWidth, y < canvasHeight, cells[y][x] == nil else { return }
            cells[y][x] = rgb
        }

        mutating func blit(_ rows: [String], _ x: Int, _ y: Int, _ colors: [Character: UInt32]) {
            for (dy, row) in rows.enumerated() {
                for (dx, ch) in row.enumerated() {
                    if let rgb = colors[ch] { put(x + dx, y + dy, rgb) }
                }
            }
        }

        /// A tiny one of the pet itself, 4x3 — a helper. Nothing below the floor.
        mutating func mini(_ x: Int, _ y: Int, eye: Bool = true) {
            let ink = sprite.palette["B"] ?? 0x888888
            let eyeColor = sprite.palette["E"] ?? 0
            for (j, row) in [".BB.", "BEBB", "B..B"].enumerated() where y + j <= floor {
                for (i, ch) in row.enumerated() where ch != "." {
                    put(x + i, y + j, ch == "E" && eye ? eyeColor : ink)
                }
            }
        }
    }

    typealias Draw = (inout Canvas) -> Void

    struct Pose {
        var eyes: EyeMode = .open
        var dx = 0
        var dy = 0
        /// Rows above `shearRow` shift sideways by `shear`: the dizzy head
        /// shake (row 8), or a lean from the waist.
        var shear = 0
        var shearRow = 8
        /// +n: n rows taller at the waist; −n: n rows shorter.
        var stretch = 0
        /// A screen face's glyph moves down (1) to look down.
        var glyphDy = 0
        var overlays: [Overlay] = []
        /// Props drawn before the pet (behind it) and after it.
        var under: [Draw] = []
        var over: [Draw] = []
    }

    static func frac(_ v: Double) -> Double { v - v.rounded(.down) }
    static func step(_ t: Double, _ period: Double) -> Int { Int((max(t, 0) / period).rounded(.down)) }

    /// How long a celebrating pet crouches before it jumps. Only seen when
    /// `t` is counted from the reaction's start (PixelPetView does that).
    public static let celebrateAnticipation: Double = 0.24

    // MARK: - Idle and sleep

    /// Idle, a 12s carousel of 0.4s beats: glances, blinks and a hop, a
    /// stretch with a yawn, settling down for a moment, a look round and a
    /// paw rubbing its face. Feet stay planted except for the hop.
    enum IdleBeat { case rest, blink, left, right, hop, stretch, yawn, sit, look, groom }
    static let idleBeats: [IdleBeat] = [
        .rest, .rest, .rest, .blink, .rest, .rest, .left, .left, .rest, .right, .right, .rest,
        .stretch, .stretch, .yawn, .yawn, .groom, .groom, .rest, .hop, .rest, .sit, .sit, .sit,
        .rest, .rest, .look, .look, .rest, .blink,
    ]

    static func idle(_ sprite: PetSprite, _ t: Double) -> Pose {
        var p = Pose()
        switch idleBeats[step(t, 0.4) % idleBeats.count] {
        case .rest: break
        case .blink: p.eyes = .closed
        case .left: p.eyes = .lookLeft
        case .right: p.eyes = .lookRight
        case .hop: p.dy = -1
        case .stretch: p.stretch = 1
        case .yawn: p.stretch = 1; p.eyes = .closed
        case .sit: p.stretch = -1
        case .look: p.eyes = frac(t / 0.4) < 0.5 ? .lookLeft : .lookRight
        case .groom:
            p.eyes = .closed
            let up = frac(t / 0.2) < 0.5
            let y = sprite.eyeBottom + originY - (up ? 1 : 0)
            let x = sprite.right + originX - 2
            p.over = [{ c in c.put(x, y, c.paw) }]
        }
        return p
    }

    /// Asleep, curled up: the top half sinks a row on the out-breath; the
    /// feet stay on the floor.
    static func sleep(_ t: Double) -> Pose {
        var p = Pose(eyes: .closed)
        p.stretch = frac(t / 2.4) < 0.5 ? -1 : 0
        let a = frac(t / 2.4), b = frac(t / 2.4 + 0.5)
        p.overlays = [
            Overlay(glyph: .smallZ, x: 14 + Int(a * 3), y: 5 - Int(a * 5), rgb: FX.zzz),
            Overlay(glyph: .bigZ, x: 16 + Int(b * 2), y: 3 - Int(b * 4), rgb: FX.zzz),
        ]
        return p
    }

    /// The "!" or "?" over a pet that needs you: on for three beats of four.
    static func alert(_ p: inout Pose, _ t: Double, _ glyph: Glyph) {
        if step(t, 0.25) % 4 != 3 {
            p.overlays.append(Overlay(glyph: glyph, x: glyph == .question ? 16 : 17, y: 1, rgb: FX.alert))
        }
    }

    // MARK: - Work (design/v25 B: crafts of the burrow)

    static func work(_ work: PetWork, _ sprite: PetSprite, _ t: Double) -> Pose {
        // Stepped two cells aside to make room for its work on the right.
        var p = Pose(dx: -2)
        let right = sprite.right + originX - 2
        let cx = Double(sprite.left + sprite.right) / 2 + Double(originX) - 2
        let top = sprite.bodyTop + originY

        switch work {
        case .think:
            // A firefly drifts round its head; its eyes follow it.
            let a = 2 * Double.pi * t / 4.8
            let fx = Int((cx + 5.5 * sin(a)).rounded())
            let fy = top - 3 + Int((1.4 * sin(2 * a)).rounded())
            let a0 = 2 * Double.pi * (t - 0.25) / 4.8
            let tx = Int((cx + 5.5 * sin(a0)).rounded())
            let ty = top - 3 + Int((1.4 * sin(2 * a0)).rounded())
            p.eyes = Double(fx) < cx - 2 ? .lookLeft : Double(fx) > cx + 2 ? .lookRight : .open
            if t.truncatingRemainder(dividingBy: 4.8) > 4.55 { p.eyes = .closed }
            let glow = 0.75 + 0.25 * sin(2 * Double.pi * t / 0.8)
            p.over = [{ c in
                if (tx, ty) != (fx, fy) { c.put(tx, ty, FX.fireflyDim) }
                c.put(fx, fy, UInt32(0).mixed(with: FX.firefly, by: glow))
            }]

        case .read:
            // Holds an open book, eyes down on it; now and then a page turns.
            let ph = t.truncatingRemainder(dividingBy: 2.4)
            p.eyes = .down
            p.glyphDy = 1
            p.over = [{ c in
                let x0 = right, y0 = c.floor - 5
                c.blit(["ww.ww", "lw.lw", "ww.ww", "CCCCC"], x0, y0, ["w": FX.white, "l": FX.readDark, "C": FX.readDark])
                // The page lifts on the right, goes over the spine, lands left.
                if ph >= 2.0, ph < 2.12 {
                    c.put(x0 + 4, y0 - 1, FX.white); c.put(x0 + 3, y0 - 1, FX.white)
                } else if ph >= 2.12, ph < 2.24 {
                    c.put(x0 + 2, y0 - 1, FX.white); c.put(x0 + 2, y0 - 2, FX.white)
                } else if ph >= 2.24, ph < 2.36 {
                    c.put(x0 + 1, y0 - 1, FX.white); c.put(x0, y0 - 1, FX.white)
                }
                c.put(x0 - 1, y0 + 2, c.paw)
            }]

        case .search:
            // Digs for it: leans in, paws scrape, clods fly back over its head.
            p.shear = 1
            p.shearRow = sprite.waist
            p.eyes = .down
            p.glyphDy = 1
            let scrape = step(t, 0.12) % 2
            p.over = [{ c in
                let f = c.floor
                c.put(right + 1, f - scrape, c.paw)
                c.put(right + 1, f - 1 - scrape, c.paw)
                c.put(right + 2, f, FX.earthDark)
                c.put(right + 3, f, FX.earth)
                c.put(right + 4, f, FX.earthDark)
                c.put(right + 3, f - 1, FX.earth)
                if scrape == 1 { c.put(right + 4, f - 1, FX.earthDark) } else { c.put(right + 2, f - 1, FX.earthDark) }
            }, { c in
                let f = c.floor
                for k in 0..<3 {
                    var u = frac((t + Double(k) * 0.3) / 0.9)
                    if u > 0.8 { continue }
                    u = u / 0.8
                    let x = Int((Double(right + 1) + Double(1 - (right + 1)) * u).rounded())
                    let y = Int((Double(f - 1) - sin(Double.pi * u) * Double(f - top + 2)).rounded())
                    c.putBehind(x, y, k != 1 ? FX.earth : FX.earthDark)
                }
            }]

        case .edit:
            // Builds a little wall a brick at a time, three rows high.
            let n = step(t, 0.7), ph = frac(t / 0.7)
            p.eyes = .lookRight
            p.over = [{ c in
                let f = c.floor
                let bricks = (0..<3).flatMap { r in (0..<2).map { b in (r, b) } }
                let placed = n % 6
                for (r, b) in bricks.prefix(placed) {
                    for dx in 0..<2 { c.put(16 + b * 2 + dx, f - r, (r + b) % 2 == 0 ? FX.edit : FX.editDark) }
                }
                // The brick in its paw, on the way to its spot.
                let (r, b) = bricks[placed]
                let tx = 16 + b * 2, ty = f - r
                let u = min(1.0, ph / 0.6)
                let sx = right + 1, sy = f - 4
                let bx = Int((Double(sx) + Double(tx - sx) * u).rounded())
                let by = Int((Double(sy) + Double(ty - sy) * u - sin(Double.pi * u) * 1.5).rounded())
                if ph < 0.6 {
                    c.put(bx, by, FX.edit); c.put(bx + 1, by, FX.edit); c.put(bx - 1, by + 1, c.paw)
                } else {
                    c.put(right + 1, f - 3, c.paw)
                }
            }]

        case .shell:
            // Pulls the lever of a little machine: the lamp goes green and
            // the output puffs out.
            let ph = t.truncatingRemainder(dividingBy: 1.2)
            p.eyes = .lookRight
            p.over = [{ c in
                let f = c.floor
                let lampOn = ph >= 0.45 && ph < 1.05
                c.blit(["LLLL", "GgGG", "GGGG"], 16, f - 2,
                       ["L": FX.metalLight, "G": FX.metalDark, "g": lampOn ? FX.shell : FX.lampOff])
                let stick: [(Int, Int)], knob: (Int, Int)
                if ph < 0.35 || ph >= 0.95 {
                    stick = [(18, f - 3), (18, f - 4)]; knob = (18, f - 5)
                } else if ph < 0.45 || ph >= 0.8 {
                    stick = [(17, f - 3)]; knob = (16, f - 4)
                } else {
                    stick = [(17, f - 3)]; knob = (16, f - 3)
                }
                for (x, y) in stick { c.put(x, y, FX.steel) }
                c.put(knob.0, knob.1, FX.white)
                c.put(knob.0 - 1, knob.1, c.paw)
                if lampOn {
                    let k = Int((ph - 0.45) / 0.1)
                    for j in 0..<2 {
                        let y = f - 3 - ((k + j * 3) % 5)
                        if y < f - 2 { c.put(19, y, FX.shell) }
                    }
                }
            }]

        case .web:
            // A periscope up out of the burrow, turning to look outside.
            let side = step(t, 1.6) % 2
            let glint = frac(t / 1.6) < 0.12
            p.eyes = side == 0 ? .lookLeft : .lookRight
            let px = Int(cx) + 3
            p.under = [{ c in
                for y in (top - 4)..<top { c.putBehind(px, y, FX.steel) }
                c.put(px, top - 5, FX.metalLight)
                c.put(px + (side == 1 ? 1 : -1), top - 5, glint ? FX.white : FX.web)
            }]

        case .agent:
            // Calls a helper up the tunnel; it looks, hops and dives back down.
            let ph = t.truncatingRemainder(dividingBy: 2.4)
            p.eyes = .lookRight
            p.over = [{ c in
                let f = c.floor
                let y: Int?
                if ph < 0.3 { y = f - 2 + 3 - Int(ph / 0.1) }
                else if ph < 1.3 { y = f - 2 }
                else if ph < 1.5 { y = f - 3 }
                else if ph < 1.8 { y = f - 2 + Int((ph - 1.5) / 0.1) + 1 }
                else { y = nil }
                if let y { c.mini(16, y, eye: !(ph >= 0.8 && ph < 0.9)) }
                if ph >= 1.8, ph < 2.1 {
                    c.put(17, f, FX.earth)
                    c.put(18, f - (ph < 1.95 ? 1 : 0), FX.earthDark)
                }
                if ph >= 0.4, ph < 1.3 { c.put(right + 1, f - 5, c.paw) }
            }]

        case .other:
            // A hammer on a little anvil — tools in general.
            let ph = t.truncatingRemainder(dividingBy: 0.9)
            p.eyes = ph >= 0.46 && ph < 0.56 ? .closed : .lookRight
            p.over = [{ c in
                let f = c.floor
                c.blit(["LLL", ".G."], 17, f - 1, ["L": FX.metalLight, "G": FX.metalDark])
                let head: [(Int, Int)], handle: [(Int, Int)]
                if ph < 0.4 || ph >= 0.82 {
                    head = [(16, f - 6), (17, f - 6)]; handle = [(16, f - 5), (16, f - 4)]
                } else if ph < 0.46 || ph >= 0.72 {
                    head = [(18, f - 5), (18, f - 4)]; handle = [(17, f - 4)]
                } else {
                    head = [(18, f - 2), (19, f - 2)]; handle = [(17, f - 3)]
                }
                for (x, y) in handle { c.put(x, y, FX.steel) }
                for (x, y) in head { c.put(x, y, FX.metalLight) }
                c.put(16, f - 3, c.paw)
                if ph >= 0.46, ph < 0.62 {
                    let k = Int((ph - 0.46) / 0.08)
                    c.put(19, f - 4 - k, FX.white)
                    c.put(17, f - 4 - k, FX.grey)
                }
            }]

        case .compact:
            // Gathers loose bits into a bundle, ties it, tucks it into the ground.
            let ph = t.truncatingRemainder(dividingBy: 3.6)
            p.eyes = .lookRight
            let loose = [(16, -3, 0), (19, -2, 2), (16, 0, 1), (19, 0, 4), (18, -4, 3)]
            let target = [(17, -1), (18, -1), (17, 0), (18, 0), (18, -1)]
            p.over = [{ c in
                let f = c.floor
                if ph < 0.4 {
                    // The bits drop in.
                    for (i, (x, y, col)) in loose.enumerated() {
                        let yy = i % 2 == 1 ? y - max(0, 3 - Int(ph / 0.1)) : y
                        c.put(x, f + yy, FX.code[col])
                    }
                } else if ph < 1.3 {
                    let u = min(1.0, (ph - 0.4) / 0.8)
                    for (i, (x, y, col)) in loose.enumerated() {
                        let (tx, ty) = target[i]
                        c.put(Int((Double(x) + Double(tx - x) * u).rounded()),
                              f + Int((Double(y) + Double(ty - y) * u).rounded()), FX.code[col])
                    }
                    c.put(right + 1, f - 1, c.paw)
                } else if ph < 2.9 {
                    for x in [17, 18] { for y in [-1, 0] { c.put(x, f + y, FX.earth) } }
                    let pat = step(ph, 0.3) % 2
                    c.put(17, f - 2, FX.alert)
                    if pat == 1 { c.put(18, f - 2, FX.alert) }
                    c.put(16, f - 1 - pat, c.paw)
                } else if ph < 3.3 {
                    let s = Int((ph - 2.9) / 0.13)
                    for x in [17, 18] { for y in [-1, 0] where y + s <= 0 { c.put(x, f + y + s, FX.earth) } }
                    if s <= 1 { c.put(17, f - 2 + s, FX.alert) }
                }
            }]
        }
        return p
    }

    // MARK: - Poses

    static func pose(_ state: PetState, t: Double, sprite: PetSprite, work: PetWork?) -> Pose {
        var p = Pose()
        switch state {
        case .sleep:
            p = sleep(t)
        case .idle:
            p = idle(sprite, t)
        case .busy:
            p = Self.work(work ?? .think, sprite, t)
        case .attention:
            // A sentry: stands tall and looks straight at you. Still.
            p.stretch = 1
            alert(&p, t, .bang)
        case .question:
            // Head tilted as if hearing a sound, one side then the other.
            p.shear = step(t, 1.2) % 2 == 0 ? 1 : -1
            p.shearRow = sprite.waist
            alert(&p, t, .question)
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
            p.shear = beat == 0 ? 1 : -1
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
        // Looking down keeps the eye's lower half, like a shut eye without
        // the narrow eye's dash.
        case .closed, .down: return !top
        case .happy: return top
        case .lookLeft: return !wide || left
        case .lookRight: return !wide || !left
        case .diagonalA: return top == left
        case .diagonalB: return top != left
        }
    }

    /// A screen face's eyes, like the official Codex pet's: >_ awake, v v
    /// shut, ^ ^ happy, x x hurt. Looks slide the whole glyph a cell; looking
    /// down drops it a row (Pose.glyphDy).
    static func screenGlyph(_ mode: EyeMode) -> [String] {
        switch mode {
        case .open, .lookLeft, .lookRight, .down: return ["1.......", ".1......", "1..1111."]
        case .closed: return ["........", "1.1..1.1", ".1....1."]
        case .happy: return [".1....1.", "1.1..1.1", "........"]
        case .diagonalA, .diagonalB: return ["1.1..1.1", ".1....1.", "1.1..1.1"]
        }
    }

    /// Which way an idle pet looks: -1 left, 0 straight ahead, 1 right.
    /// Applied only while its eyes are open and resting, so blinks and the
    /// idle carousel's own glances still play.
    /// `work` matters only while the pet is busy: what it acts out.
    public static func pixels(sprite: PetSprite, state: PetState, t: Double, gaze: Int = 0, work: PetWork? = nil) -> [PetPixel] {
        var pose = pose(state, t: t, sprite: sprite, work: work)
        if state == .idle, gaze != 0, pose.eyes == .open {
            pose.eyes = gaze < 0 ? .lookLeft : .lookRight
        }
        var canvas = Canvas(sprite: sprite, floor: sprite.bodyBottom + originY + pose.dy)
        for draw in pose.under { draw(&canvas) }

        let rows = sprite.rows
        func isEye(_ x: Int, _ y: Int) -> Bool {
            y >= 0 && y < rows.count && x >= 0 && x < rows[y].count && rows[y][x] == "E"
        }
        // Where sprite row y lands: a stretch repeats the waist row, a
        // squash drops rows from the waist up; the rest moves with them.
        let waist = sprite.waist, s = pose.stretch
        func rowsFor(_ y: Int) -> [Int] {
            if s > 0 {
                if y < waist { return [y - s] }
                if y == waist { return (0...s).map { y - s + $0 } }
                return [y]
            }
            if s < 0, y <= waist {
                return y > waist + s ? [] : [y - s]
            }
            return [y]
        }
        func place(_ x: Int, _ y: Int, _ rgb: UInt32?) {
            let sx = y < pose.shearRow ? pose.shear : 0
            for yy in rowsFor(y) {
                canvas.put(x + originX + sx + pose.dx, yy + originY + pose.dy, rgb)
            }
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
                    if out >= 0, out < row.count, row[out] != "." {
                        slidEyes.append((out, y))
                    }
                }
                place(x, y, sprite.palette[key])
            }
        }
        for (x, y) in slidEyes {
            place(x, y, sprite.palette["E"])
        }
        if let face = sprite.screenFace {
            let look = pose.eyes == .lookLeft ? -1 : pose.eyes == .lookRight ? 1 : 0
            for (j, row) in screenGlyph(pose.eyes).enumerated() {
                for (i, ch) in row.enumerated() where ch == "1" {
                    place(face.x + i + look, face.y + j + pose.glyphDy, sprite.palette["E"])
                }
            }
        }
        for draw in pose.over { draw(&canvas) }

        for o in pose.overlays {
            for (dy, row) in o.glyph.rows.enumerated() {
                for (dx, ch) in row.enumerated() where ch == "1" {
                    canvas.put(o.x + dx, o.y + dy, o.rgb)
                }
            }
        }

        var out: [PetPixel] = []
        for y in 0..<canvasHeight {
            for x in 0..<canvasWidth {
                if let rgb = canvas.cells[y][x] { out.append(PetPixel(x: x, y: y, rgb: rgb)) }
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

    /// Rightmost sprite column with any pixel.
    var right: Int {
        rows.compactMap { $0.lastIndex { $0 != "." } }.max() ?? 15
    }

    /// Leftmost sprite column with any pixel.
    var left: Int {
        rows.compactMap { $0.firstIndex { $0 != "." } }.min() ?? 0
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

    /// This colour `amount` of the way to `other`.
    func mixed(with other: UInt32, by amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let a = Int((self >> shift) & 0xFF), b = Int((other >> shift) & 0xFF)
            return UInt32((Double(a) + Double(b - a) * amount).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
}
