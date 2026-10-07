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

/// Opens the Settings window from a menu bar app. An accessory app is not
/// active, so it is activated first, or the window would open behind other
/// apps. `openSettings` (macOS 14, in the SDKs of Swift 6 toolchains) is
/// captured from the panel's environment; older toolchains get
/// `SettingsLink` on macOS 14, and macOS 13 the responder chain action.
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

    /// A button that opens Settings.
    struct Button<Label: View>: View {
        @ViewBuilder var label: () -> Label

        var body: some View {
            #if compiler(>=6.0)
            SwiftUI.Button(action: SettingsOpener.open, label: label)
                .background(Capture())
            #else
            if #available(macOS 14, *) {
                SettingsLink(label: label)
                    .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
            } else {
                SwiftUI.Button(action: SettingsOpener.open, label: label)
            }
            #endif
        }
    }

    #if compiler(>=6.0)
    private struct Capture: View {
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
    #endif
}
