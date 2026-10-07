import SwiftUI

struct SettingsView: View {
    @AppStorage("cliPath") private var cliPath = ""
    @AppStorage("refreshInterval") private var refreshInterval = 30

    var body: some View {
        Form {
            TextField("CLI path", text: $cliPath, prompt: Text("Automatic"))
            Stepper("Refresh every \(refreshInterval) seconds", value: $refreshInterval, in: 15...600, step: 15)
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { DebugHooks.writeState() }
    }
}

/// Opens the Settings window from a menu bar app: `openSettings` from macOS
/// 14 (captured from the panel's environment), the responder chain action on
/// macOS 13. An accessory app is not active, so it is activated first, or the
/// window would open behind other apps.
@MainActor
enum SettingsOpener {
    static var action: (() -> Void)?

    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if let action {
            action()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    struct Capture: View {
        var body: some View {
            if #available(macOS 14, *) {
                Modern()
            }
        }
    }

    @available(macOS 14, *)
    private struct Modern: View {
        @Environment(\.openSettings) private var openSettings

        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear { SettingsOpener.action = { openSettings() } }
        }
    }
}
