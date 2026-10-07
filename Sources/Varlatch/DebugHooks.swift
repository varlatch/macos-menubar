import AppKit
import Combine
import notify
import VarlatchKit

/// Checks without synthetic input. With the `debugHooks` default on
/// (`defaults write com.varlatch.menubar debugHooks -bool true`), the app
/// writes its state to `debug-state.json` in its Application Support
/// directory whenever it changes, and answers
/// `notifyutil -p com.varlatch.menubar.debug.<name>` for these names:
/// dump-state, open-panel, settings, refresh, and these actions on the
/// first server shown (or the one "Log In" would use): sign-in, cancel,
/// verify, logout; and quit.
@MainActor
enum DebugHooks {
    static let prefix = "com.varlatch.menubar.debug."
    private static var tokens: [Int32] = []
    private static var events: [String: [String]] = [:]
    private static var subscriptions: Set<AnyCancellable> = []

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "debugHooks") }

    static var stateURL: URL {
        AppSupport.directory.appendingPathComponent("debug-state.json")
    }

    static func install() {
        guard enabled else { return }
        let actions: [String: @MainActor () -> Void] = [
            "dump-state": { writeState() },
            "open-panel": { StatusItem.openPanel() },
            "settings": { SettingsOpener.open() },
            "refresh": { Task { await AppController.shared.store.refresh() } },
            "sign-in": { firstServer.map(AppController.shared.signIn(to:)) },
            "cancel": { AppController.shared.cancelSignIn() },
            "verify": { AppController.shared.verify() },
            "logout": { firstServer.map(AppController.shared.logout) },
            "quit": { NSApp.terminate(nil) },
        ]
        for (name, action) in actions {
            var token: Int32 = 0
            notify_register_dispatch(prefix + name, &token, DispatchQueue.main) { _ in
                MainActor.assumeIsolated { action() }
            }
            tokens.append(token)
        }
        // After each change has been applied.
        for publisher in [AppController.shared.store.objectWillChange.eraseToAnyPublisher(),
                          AppController.shared.signIn.objectWillChange.eraseToAnyPublisher(),
                          AppController.shared.objectWillChange.eraseToAnyPublisher()] {
            publisher
                .receive(on: RunLoop.main)
                .sink { _ in writeState() }
                .store(in: &subscriptions)
        }
        writeState()
    }

    private static var firstServer: String? {
        let store = AppController.shared.store
        return store.servers.first?.server ?? store.knownServer
    }

    /// Keeps the last values of something that happened, such as the
    /// notifications posted, for the state file.
    static func record(_ key: String, _ values: [String]) {
        guard enabled else { return }
        events[key, default: []].append(contentsOf: values)
        writeState()
    }

    static func writeState() {
        guard enabled else { return }
        let controller = AppController.shared
        let store = controller.store
        let now = Date()
        var state: [String: Any] = [
            "bundlePath": Bundle.main.bundlePath,
            "environmentPATH": ProcessInfo.processInfo.environment["PATH"] ?? "",
            "cliPath": store.cliPath ?? "",
            "cliState": "\(store.cliState)",
            "cliVersion": store.cliVersion?.description ?? "",
            "overall": store.overall(now: now).rawValue,
            "servers": store.servers.map { server -> String in
                let probe = store.probe(for: server).map { " · " + Sessions.probeText($0) } ?? ""
                return "\(server.server) \(server.health(now: now).rawValue): \(Sessions.detail(for: server, now: now))\(probe)"
            },
            "knownServer": store.knownServer ?? "",
            "rememberedServers": store.memory.servers,
            "signIn": "\(controller.signIn.state)",
            "verifying": store.verifying,
            "verifyError": store.verifyError ?? "",
            "loggingOut": Array(controller.loggingOut),
            "hiddenServers": store.allServers.count - store.servers.count,
            "menuBarItemShown": controller.menuBarItemShown,
            "toolTip": StatusItem.button?.toolTip ?? "",
            "panelOpen": StatusItem.isPanelOpen,
            "notificationAuthorization": controller.notifier.authorization,
            "launchMethod": "\(controller.loginItem.method)",
            "loginItemStatus": controller.loginItem.status.rawValue,
            "loginItemError": controller.loginItem.lastError,
            "preferences": "\(store.preferences)",
            "windows": NSApp.windows.filter(\.isVisible).map {
                "\($0.className) frame=\(NSStringFromRect($0.frame))"
            },
            "writtenAt": ISO8601DateFormatter().string(from: now),
        ]
        for (key, values) in events { state[key] = Array(values.suffix(20)) }
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: stateURL, options: .atomic)
        } catch {
            NSLog("Varlatch: cannot write debug state: \(error)")
        }
    }
}

/// `~/Library/Application Support/com.varlatch.menubar/`.
enum AppSupport {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.varlatch.menubar")
    }
}
