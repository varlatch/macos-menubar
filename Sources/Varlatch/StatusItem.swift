import AppKit

/// The menu bar item SwiftUI's `MenuBarExtra` creates, found from inside
/// the app: to open its panel (on the first launch, a notification click,
/// or opening the app again) and to give it a tooltip.
@MainActor
enum StatusItem {
    static var button: NSStatusBarButton? {
        for window in NSApp.windows where window.className.contains("StatusBarWindow") {
            if let button = find(in: window.contentView) { return button }
        }
        return nil
    }

    static var isPanelOpen: Bool {
        NSApp.windows.contains { $0.className.contains("MenuBarExtraWindow") && $0.isVisible }
    }

    /// Opens the panel, the way a click on the icon does.
    static func openPanel() {
        guard !isPanelOpen else { return }
        button?.performClick(nil)
    }

    static func updateToolTip() {
        // After the change has been applied.
        DispatchQueue.main.async {
            button?.toolTip = AppController.shared.toolTip()
        }
    }

    private static func find(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let found = find(in: sub) { return found }
        }
        return nil
    }
}
