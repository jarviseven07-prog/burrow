import SwiftUI
import CodeIslandCore

/// Buddy pet (anthropics/claude-desktop-buddy, redrawn as 16x16 pixel art).
/// Frames come from `PetFrame` in CodeIslandCore; this view only paints them.
///
/// Pixels snap to half-point steps so every sprite pixel covers whole Retina
/// pixels (27pt → 1.5pt per pixel, 24pt sprite) instead of smearing.
struct PixelPetView: View {
    let species: PetSpecies
    let state: PetState
    var size: CGFloat = 27
    /// When the current reaction began; its frames are counted from here.
    var phaseStart: Date? = nil
    /// What it is working on, above its laptop while busy.
    var sign: PetSign? = nil
    @Environment(\.mascotSpeed) private var speed

    private var cell: CGFloat { max(0.5, (size / 16 * 2).rounded(.down) / 2) }

    var body: some View {
        let cell = self.cell
        let sprite = species.sprite
        let state = self.state
        let sign = self.sign
        let origin = phaseStart.map { $0.timeIntervalSinceReferenceDate * speed } ?? 0
        MascotTimeline(interval: state.frameInterval) { t in
            Canvas { ctx, _ in
                let local = phaseStart == nil ? t : t - origin
                let gaze = state == .idle ? Self.gazeTowardPointer() : 0
                Self.paint(PetFrame.pixels(sprite: sprite, state: state, t: local, gaze: gaze, sign: sign), cell: cell, into: &ctx)
            }
            .frame(width: CGFloat(PetFrame.canvasWidth) * cell,
                   height: CGFloat(PetFrame.canvasHeight) * cell)
        }
        // The sprite sits 1.5 cells below the canvas centre (particles get the
        // top margin); shift so the pet itself is centred. The canvas may spill
        // past `size` — particles are allowed to, like the old mascots' glow.
        .offset(y: -1.5 * cell)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Idle pets look toward the pointer while it is up near the menu bar,
    /// on the side of the notch it is on; straight ahead otherwise.
    static func gazeTowardPointer() -> Int {
        let mouse = NSEvent.mouseLocation
        // The screen the island lives on: a pointer up on another display is
        // not "near the notch".
        let frame = islandScreenFrame()
        guard NSMouseInRect(mouse, frame, false) else { return 0 }
        guard frame.maxY - mouse.y < 260 else { return 0 }
        let dx = mouse.x - frame.midX
        if abs(dx) < 70 { return 0 }
        return dx < 0 ? -1 : 1
    }

    /// Finding the island's screen lists every window on screen (~10 ms), and
    /// each idle pet asked on every frame: the den's back, four pets at once,
    /// froze its turn for ~50 ms. Asked at most once a second now.
    private static var islandScreen: (frame: CGRect, at: Date)?

    private static func islandScreenFrame() -> CGRect {
        let now = Date()
        if let cached = islandScreen, now.timeIntervalSince(cached.at) < 1 { return cached.frame }
        let frame = ScreenDetector.preferredScreen.frame
        islandScreen = (frame, now)
        return frame
    }

    /// One rect per horizontal run of equal colour — fewer seams than per-pixel rects.
    private static func paint(_ pixels: [PetPixel], cell: CGFloat, into ctx: inout GraphicsContext) {
        var i = 0
        while i < pixels.count {
            let p = pixels[i]
            var run = 1
            while i + run < pixels.count,
                  pixels[i + run].y == p.y,
                  pixels[i + run].x == p.x + run,
                  pixels[i + run].rgb == p.rgb {
                run += 1
            }
            let rect = CGRect(x: CGFloat(p.x) * cell, y: CGFloat(p.y) * cell,
                              width: CGFloat(run) * cell, height: cell)
            ctx.fill(Path(rect), with: .color(Color(petRGB: p.rgb)))
            i += run
        }
    }
}

extension Color {
    init(petRGB rgb: UInt32) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}
