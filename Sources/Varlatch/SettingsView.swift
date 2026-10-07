import ServiceManagement
import SwiftUI
import VarlatchKit

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var store: SessionStore
    @AppStorage(Preferences.Key.launchAtLogin) private var launchAtLogin = true
    @AppStorage(Preferences.Key.refreshInterval) private var refreshInterval = Preferences.defaultRefreshInterval
    @AppStorage(Preferences.Key.notifyExpiry) private var notifyExpiry = true
    @AppStorage(Preferences.Key.showWhenLoggedOut) private var showWhenLoggedOut = true
    @AppStorage(Preferences.Key.showLocalhost) private var showLocalhost = false
    @AppStorage(Preferences.Key.sessionHours) private var sessionHours = 0
    @AppStorage(Preferences.Key.cliPath) private var cliPath = ""
    @AppStorage(Preferences.Key.checkUpdates) private var checkUpdates = false
    @State private var loginStatus = LoginItemController.Status.off
    /// Edited here, applied on Return or Choose, not on every keystroke.
    @State private var cliPathDraft = ""

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
                Picker("Session length", selection: $sessionHours) {
                    Text("Server default (12 hours)").tag(0)
                    Divider()
                    ForEach(1...24, id: \.self) { hours in
                        Text(hours == 1 ? "1 hour" : "\(hours) hours").tag(hours)
                    }
                }
            } footer: {
                footnote("How long a new sign-in lasts. Applies to every sign-in from this app, renewals included.")
            }
            Section {
                Stepper(value: $refreshInterval, in: Preferences.minimumRefreshInterval...3600, step: 15) {
                    LabeledContent("Check sessions every", value: "\(max(Preferences.minimumRefreshInterval, refreshInterval)) seconds")
                }
                Toggle("Notify before a session expires", isOn: $notifyExpiry)
                Toggle("Show in the menu bar when logged out", isOn: $showWhenLoggedOut)
                Toggle("Show localhost servers", isOn: $showLocalhost)
            } footer: {
                footnote("Checking sessions reads local files only; nothing goes over the network.")
            }
            Section {
                HStack {
                    TextField("CLI path", text: $cliPathDraft, prompt: Text("Automatic"))
                        .onSubmit { cliPath = cliPathDraft }
                    Button("Choose…", action: choose)
                }
                LabeledContent("In use") {
                    Text(cliSummary)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Toggle("Check for new CLI releases", isOn: $checkUpdates)
            } footer: {
                footnote("Leave the path empty to find the CLI in /opt/homebrew/bin, /usr/local/bin, or ~/.local/bin. "
                         + "The release check asks GitHub for the latest release, anonymously, at most once an hour.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            cliPathDraft = cliPath
            refreshLoginStatus()
        }
        .onChange(of: cliPath) { path in cliPathDraft = path }
        .onChange(of: launchAtLogin) { _ in
            // After the controller has applied it.
            Task { refreshLoginStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginStatus()
        }
    }

    private var cliSummary: String {
        guard let path = store.cliPath else {
            switch store.cliState {
            case .pathUnusable: return "Cannot run the path above"
            default: return "Not found"
            }
        }
        let kind: String
        switch CLIInstall.kind(of: path) {
        case .homebrew: kind = "Homebrew"
        case .release: kind = "release build"
        case .checkout: kind = "source checkout"
        case .custom: kind = "custom"
        }
        let version = store.cliVersion.map { " \($0)" } ?? ""
        return "\(PanelView.abbreviated(path))\(version), \(kind)"
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the varlatch CLI"
        panel.directoryURL = URL(fileURLWithPath: store.cliPath.map { ($0 as NSString).deletingLastPathComponent } ?? "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            cliPath = url.path
            cliPathDraft = url.path
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
    @MainActor
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
