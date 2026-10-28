// Renders the Burrow mark (Sources/CodeIslandCore/BurrowLogo.swift) into
// the app icon files:
//   - AppIcon.icon/Assets/burrow.png      Icon Composer layer (no tile; the
//                                         .icon's own fill is the night tile)
//   - Sources/CodeIsland/Resources/AppIcon.icns   fallback with the tile
//   - design/v06-app/icon-1024.png        preview
//
//   swiftc -O Sources/CodeIslandCore/BurrowLogo.swift scripts/burrow_icon/main.swift -o .build/gen-icon
//   .build/gen-icon
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func render(size: Int, background: Bool) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: the tile sits inside a ~10% margin.
    let inset = background ? CGFloat(size) * 0.1 : 0
    let rect = CGRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
    if background {
        ctx.setShadow(offset: CGSize(width: 0, height: -CGFloat(size) * 0.01), blur: CGFloat(size) * 0.03,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    }
    BurrowLogo.draw(in: ctx, rect: rect, background: background)
    if background { ctx.endTransparencyLayer() }
    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    print("wrote \(path)")
}

try write(render(size: 1024, background: false), "AppIcon.icon/Assets/burrow.png")
try write(render(size: 1024, background: true), "design/v06-app/icon-1024.png")

// .icns via iconutil
let iconset = root.appendingPathComponent(".build/Burrow.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base, background: true).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2, background: true).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Sources/CodeIsland/Resources/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote Sources/CodeIsland/Resources/AppIcon.icns" : "iconutil failed")
