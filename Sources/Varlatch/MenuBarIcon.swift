import AppKit

/// The Varlatch mark for the menu bar: a template image in the system's
/// monochrome, and with a small colored badge when something needs
/// attention. Color stays in the badge.
enum MenuBarIcon {
    enum Badge: String {
        case none, warning, error
    }

    /// Points; the mark keeps its aspect ratio.
    static let height: CGFloat = 16

    static let mark: NSImage = {
        let image = Bundle.main.image(forResource: "MenuBarIcon") ?? NSImage(
            systemSymbolName: "key.fill", accessibilityDescription: "Varlatch") ?? NSImage()
        let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1
        image.size = NSSize(width: (height * ratio).rounded(), height: height)
        image.isTemplate = true
        return image
    }()

    static func image(badge: Badge) -> NSImage {
        guard badge != .none else { return mark }
        let color: NSColor = badge == .warning ? .systemOrange : .systemRed
        let markSize = mark.size
        let size = NSSize(width: markSize.width + 2, height: markSize.height)
        // Drawn when the menu bar draws it, so the mark follows the menu
        // bar's own light or dark appearance like a template image does.
        let image = NSImage(size: size, flipped: false) { rect in
            let markRect = NSRect(origin: .zero, size: markSize)
            mark.draw(in: markRect)
            NSColor.labelColor.set()
            markRect.fill(using: .sourceAtop)
            let d: CGFloat = 7
            let dot = NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
