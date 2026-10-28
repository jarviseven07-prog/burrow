import XCTest
import SwiftUI
@testable import CodeIsland

/// The den's header straddles the notch: nothing it draws may sit under it,
/// in either state of the quit button (review #9).
@MainActor
final class BurrowDenHeaderLayoutTests: XCTestCase {
    private let width: CGFloat = 380, notch: CGFloat = 185, height: CGFloat = 32

    func testNothingIsDrawnUnderTheNotch() throws {
        let armed = QuitConfirmation(quit: {}, schedule: { _, _ in {} })
        armed.press()
        XCTAssertTrue(armed.isArmed)
        for (label, quit) in [("resting", QuitConfirmation(quit: {})), ("armed", armed)] {
            let header = BurrowDenHeader(appState: AppState(), notchWidth: notch, quit: quit)
                .frame(width: width, height: height)
                .environment(\.colorScheme, .dark)
            let image = try OffscreenRender.hosted(header, size: CGSize(width: width, height: height), scale: 2)
            let inked = try inkedColumns(image)
            let notchCols = Int((width - notch) / 2 * 2)..<Int((width + notch) / 2 * 2)
            XCTAssertTrue(inked.intersection(Set(notchCols)).isEmpty,
                          "\(label): drawn under the notch at x≈\(inked.intersection(Set(notchCols)).sorted().first.map { CGFloat($0) / 2 } ?? 0)pt")
            XCTAssertFalse(inked.filter { $0 > notchCols.upperBound }.isEmpty, "\(label): the controls are missing")
        }
    }

    /// Pixel columns where the header drew anything opaque.
    private func inkedColumns(_ image: CGImage) throws -> Set<Int> {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var cols = Set<Int>()
        for y in 0..<h { for x in 0..<w where data[(y * w + x) * 4 + 3] > 40 { cols.insert(x) } }
        return cols
    }
}
