import AppKit
import VarlatchKit

/// The Varlatch mark for the menu bar: a template image in the system's
/// monochrome, with a small amber badge while a credential is expiring and a
/// red one when signed out, expired, or the CLI is unusable (the mark is
/// dimmed then). Color stays in the badge.
enum MenuBarIcon {
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

    private static var cache: [String: NSImage] = [:]

    static func image(for state: OverallState) -> NSImage {
        let badge = state.badge
        let dimmed = state.cliUnusable
        guard badge != .none else { return mark }
        let key = "\(badge.rawValue)-\(dimmed)"
        if let cached = cache[key] { return cached }
        let color: NSColor = badge == .warning ? .systemOrange : .systemRed
        let markSize = mark.size
        let size = NSSize(width: markSize.width + 2, height: markSize.height)
        // Drawn when the menu bar draws it, so the mark follows the menu
        // bar's own light or dark appearance as a template image does.
        let image = NSImage(size: size, flipped: false) { rect in
            let markRect = NSRect(origin: .zero, size: markSize)
            mark.draw(in: markRect)
            NSColor.labelColor.withAlphaComponent(dimmed ? 0.55 : 1).set()
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
        cache[key] = image
        return image
    }

    static func accessibilityLabel(for state: OverallState) -> String {
        switch state {
        case .loading, .ok: return "Varlatch"
        case .expiring: return "Varlatch, session expiring"
        case .expired: return "Varlatch, session expired"
        case .signedOut: return "Varlatch, not logged in"
        case .cliMissing, .unsupported, .unavailable: return "Varlatch, CLI unavailable"
        }
    }
}
