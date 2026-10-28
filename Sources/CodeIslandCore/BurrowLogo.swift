import CoreGraphics
import Foundation

/// Burrow's mark: a dark burrow (the notch) at the top of a night-blue tile,
/// with Clawd peeking out of its rim — eyes and little arms showing, the rest
/// of him still in the dark — and a warm night-light glow spilling below.
///
/// One drawing for every place the mark appears: the app icon (Icon Composer
/// layer and the .icns fallback, both made by scripts/gen_burrow_icon.swift)
/// and the logo in Settings › About.
public enum BurrowLogo {
    /// Draws the mark into `rect` of a context with the usual CoreGraphics
    /// (y-up) orientation. `background` adds the night tile and its rounded
    /// corners; without it only the burrow, Clawd and the glow are drawn.
    public static func draw(in ctx: CGContext, rect: CGRect, background: Bool = true) {
        ctx.saveGState()
        // Work on a 16 × 16 grid with y pointing down, like the pet sprites.
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: rect.width / 16, y: -rect.height / 16)

        if background {
            let tile = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 16, height: 16),
                              cornerWidth: 3.6, cornerHeight: 3.6, transform: nil)
            ctx.addPath(tile)
            ctx.clip()
            let night = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [rgb(0x232838), rgb(0x0E1016)] as CFArray,
                locations: [0, 1]
            )!
            ctx.drawLinearGradient(night, start: CGPoint(x: 8, y: 0), end: CGPoint(x: 8, y: 16), options: [])
            // A few stars.
            for (x, y, r, a) in [(2.4, 12.6, 0.16, 0.55), (13.3, 11.4, 0.12, 0.45), (12.2, 14.2, 0.1, 0.35), (3.6, 14.6, 0.09, 0.3)] {
                ctx.setFillColor(rgb(0xF3EEE6, alpha: a))
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
        }

        // The night light: warm glow under the burrow's rim.
        let glow = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [rgb(0xF5B764, alpha: 0.42), rgb(0xF5B764, alpha: 0)] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 8, y: 8.6), startRadius: 0,
                               endCenter: CGPoint(x: 8, y: 8.6), endRadius: 7.4, options: [])

        // The burrow: hangs from the top like the notch, rounder below.
        let burrow = roundedRect(CGRect(x: 2.4, y: -1, width: 11.2, height: 9.4), top: 0, bottom: 3.0)
        ctx.addPath(burrow)
        ctx.setFillColor(rgb(0x000000))
        ctx.fillPath()

        // Clawd, inside the burrow and clipped by it: only the top of him is
        // out over the rim.
        ctx.saveGState()
        ctx.addPath(burrow)
        ctx.clip()
        let body = rgb(0xDE886D)
        ctx.setFillColor(body)
        ctx.fill(CGRect(x: 5.0, y: 5.0, width: 6.0, height: 4))        // head and body
        ctx.fill(CGRect(x: 3.9, y: 6.9, width: 1.15, height: 0.9))     // left arm
        ctx.fill(CGRect(x: 10.95, y: 6.9, width: 1.15, height: 0.9))   // right arm
        ctx.setFillColor(rgb(0x000000))
        ctx.fill(CGRect(x: 6.25, y: 5.75, width: 0.7, height: 1.3))    // eyes
        ctx.fill(CGRect(x: 9.05, y: 5.75, width: 0.7, height: 1.3))
        // He fades into the dark toward the rim's edge.
        let fade = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [rgb(0x000000, alpha: 0), rgb(0x000000, alpha: 1)] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawLinearGradient(fade, start: CGPoint(x: 8, y: 7.5), end: CGPoint(x: 8, y: 8.4), options: [.drawsAfterEndLocation])
        ctx.restoreGState()

        ctx.restoreGState()
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    /// A rectangle with different top and bottom corner radii (y down).
    private static func roundedRect(_ r: CGRect, top: CGFloat, bottom: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + top), radius: top)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - bottom))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - bottom, y: r.maxY), radius: bottom)
        p.addLine(to: CGPoint(x: r.minX + bottom, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - bottom), radius: bottom)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + top))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + top, y: r.minY), radius: top)
        p.closeSubpath()
        return p
    }
}
