// Makes the icons in Resources/ from the marks in assets/. Run from the
// repository root when the marks change:
//
//   swift scripts/make-icons.swift
//
// The results are committed, so building the app does not run this.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("assets")
let resources = root.appendingPathComponent("Resources")

func load(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: assets.appendingPathComponent(name)) else {
        fatalError("cannot read assets/\(name)")
    }
    return image
}

/// A bitmap of exactly `width` x `height` pixels, drawn by `draw` in a
/// context of that many points.
func render(width: Int, height: Int, _ draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    draw(NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to url: URL) {
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func fit(_ image: NSImage, height: CGFloat, centeredIn rect: NSRect) -> NSRect {
    let width = height * image.size.width / image.size.height
    return NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
}

// Menu bar: the symbolic mark (white on transparent), 16 points high. The
// app marks it as a template image, so macOS colors it like other menu
// bar icons.
let symbolic = load("varlatch-mark-symbolic.png")
let barHeight = 16.0
let barWidth = (barHeight * symbolic.size.width / symbolic.size.height).rounded(.up)
for scale in [1, 2] {
    let w = Int(barWidth) * scale, h = Int(barHeight) * scale
    let rep = render(width: w, height: h) { rect in
        symbolic.draw(in: fit(symbolic, height: CGFloat(h), centeredIn: rect))
    }
    write(rep, to: resources.appendingPathComponent(scale == 1 ? "MenuBarIcon.png" : "MenuBarIcon@2x.png"))
}

// App icon: the full-color mark on a light tile, on the macOS icon grid
// (an 824-point rounded square in a 1024-point canvas).
let mark = load("varlatch-mark.png")
func appIcon(pixels: Int) -> NSBitmapImageRep {
    render(width: pixels, height: pixels) { rect in
        let s = rect.width / 1024
        let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.shadowBlurRadius = 20 * s
        shadow.set()
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(white: 1, alpha: 1), ending: NSColor(white: 0.9, alpha: 1))!
            .draw(in: path, angle: -90)
        mark.draw(in: fit(mark, height: 440 * s, centeredIn: tile.offsetBy(dx: 0, dy: -8 * s)))
    }
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    write(appIcon(pixels: size), to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    write(appIcon(pixels: size * 2), to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
write(appIcon(pixels: 256), to: assets.appendingPathComponent("app-icon-256.png"))
print("Wrote Resources/MenuBarIcon.png, MenuBarIcon@2x.png, AppIcon.icns")
