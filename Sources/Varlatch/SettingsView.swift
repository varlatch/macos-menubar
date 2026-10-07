import ServiceManagement
import SwiftUI
import VarlatchKit

struct SettingsView: View {
    @AppStorage(Preferences.Key.launchAtLogin) private var launchAtLogin = true
    @AppStorage(Preferences.Key.refreshInterval) private var refreshInterval = Preferences.defaultRefreshInterval
    @AppStorage(Preferences.Key.notifyExpiry) private var notifyExpiry = true
    @AppStorage(Preferences.Key.showWhenLoggedOut) private var showWhenLoggedOut = true
    @AppStorage(Preferences.Key.showLocalhost) private var showLocalhost = false
    @State private var loginStatus = LoginItemController.Status.off

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                if launchAtLogin, loginStatus == .needsApproval {
                    HStack {
                        Text("Allow Varlatch in Login Items to open it at login.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }
            Section {
                Stepper(value: $refreshInterval, in: Preferences.minimumRefreshInterval...3600, step: 15) {
                    LabeledContent("Check sessions every", value: "\(max(Preferences.minimumRefreshInterval, refreshInterval)) seconds")
                }
                Toggle("Notify before a session expires", isOn: $notifyExpiry)
                Toggle("Show in the menu bar when logged out", isOn: $showWhenLoggedOut)
                Toggle("Show localhost servers", isOn: $showLocalhost)
            } footer: {
                Text("Checking sessions reads local files only; nothing goes over the network.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refreshLoginStatus)
        .onChange(of: launchAtLogin) { _ in
            // After the controller has applied it.
            DispatchQueue.main.async(execute: refreshLoginStatus)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginStatus()
        }
    }

    private func refreshLoginStatus() {
        loginStatus = AppController.shared.loginItem.status
        DebugHooks.writeState()
    }
}

/// Opens the Settings window from a menu bar app. An accessory app is not
/// active, so it is activated first, or the window would open behind other
/// apps. `openSettings` (macOS 14, in the SDKs of Swift 6 toolchains) is
/// captured from the menu bar item's environment; otherwise the Settings
/// item of the app menu (which an accessory app has but never shows) does
/// it, and on macOS 13 the responder chain action.
@MainActor
enum SettingsOpener {
    static var action: (() -> Void)?

    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if let action {
            action()
        } else if let appMenu = NSApp.mainMenu?.items.first?.submenu,
                  let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
            appMenu.performActionForItem(at: index)
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

    /// Keeps `openSettings` from the environment it is placed in.
    struct Capture: View {
        var body: some View {
            #if compiler(>=6.0)
            if #available(macOS 14, *) {
                Modern()
            }
            #else
            EmptyView()
            #endif
        }
    }

    #if compiler(>=6.0)
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
