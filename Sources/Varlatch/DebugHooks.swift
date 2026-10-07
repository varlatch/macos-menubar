import AppKit
import notify

/// Checks without synthetic input. With the `debugHooks` default on
/// (`defaults write com.varlatch.menubar debugHooks -bool true`), the app
/// writes its state to `debug-state.json` in its Application Support
/// directory, and answers `notifyutil -p com.varlatch.menubar.debug.<name>`
/// for these names: dump-state, open-panel, notify, login-on, login-off,
/// badge-none, badge-warning, badge-error, settings.
@MainActor
enum DebugHooks {
    static let prefix = "com.varlatch.menubar.debug."
    private static var tokens: [Int32] = []

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "debugHooks") }

    static var stateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.varlatch.menubar/debug-state.json")
    }

    static func install() {
        guard enabled else { return }
        let actions: [String: @MainActor () -> Void] = [
            "dump-state": { writeState() },
            "open-panel": { openPanel() },
            "notify": { Task { await SpikeModel.shared.sendTestNotification() } },
            "login-on": { SpikeModel.shared.setLaunchAtLogin(true) },
            "login-off": { SpikeModel.shared.setLaunchAtLogin(false) },
            "badge-none": { SpikeModel.shared.badge = .none; writeState() },
            "badge-warning": { SpikeModel.shared.badge = .warning; writeState() },
            "badge-error": { SpikeModel.shared.badge = .error; writeState() },
            "settings": { SettingsOpener.open() },
        ]
        for (name, action) in actions {
            var token: Int32 = 0
            notify_register_dispatch(prefix + name, &token, DispatchQueue.main) { _ in
                MainActor.assumeIsolated { action() }
            }
            tokens.append(token)
        }
    }

    static func writeState() {
        guard enabled else { return }
        var state = SpikeModel.shared.state()
        state["writtenAt"] = ISO8601DateFormatter().string(from: Date())
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: stateURL, options: .atomic)
        } catch {
            NSLog("Varlatch: cannot write debug state: \(error)")
        }
    }

    /// Opens the menu bar panel the way a click on the icon does, from inside
    /// the app.
    static func openPanel() {
        for window in NSApp.windows where window.className.contains("StatusBarWindow") {
            if let button = findStatusButton(in: window.contentView) {
                button.performClick(nil)
                return
            }
        }
    }

    private static func findStatusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let found = findStatusButton(in: sub) { return found }
        }
        return nil
    }
}
