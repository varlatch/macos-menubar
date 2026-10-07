import AppKit
import Combine
import VarlatchKit

/// Ties the session store to the rest of the app: settings, notifications,
/// launch at login, and the menu bar item.
@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    /// Whether the menu bar item shows: always, except with no credentials
    /// stored and "show when logged out" off. Taking the item out of the
    /// menu bar by hand lasts until the next change of state.
    ///
    /// Not `@Published`: `MenuBarExtra` writes back the value it already
    /// has, and announcing every write would loop.
    var menuBarItemShown: Bool {
        get { shown }
        set {
            guard newValue != shown else { return }
            objectWillChange.send()
            shown = newValue
        }
    }
    private var shown = true

    let store: SessionStore
    let notifier = Notifier()
    let loginItem = LoginItemController()
    private var subscriptions: Set<AnyCancellable> = []

    private init() {
        UserDefaults.standard.register(defaults: Preferences.registrationDefaults)
        store = SessionStore(preferences: Preferences(UserDefaults.standard))
    }

    func launch() {
        let firstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunched")
        UserDefaults.standard.set(true, forKey: "hasLaunched")

        notifier.install()
        store.onExpiryEvents = { [weak self] events in
            guard let self, self.store.preferences.notifyExpiry else { return }
            self.notifier.post(events)
        }
        // A server that is fine again, or gone, takes its expiry
        // notification with it.
        store.$allServers
            .sink { [weak self] servers in self?.notifier.withdrawResolved(servers) }
            .store(in: &subscriptions)
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.updateMenuBarItem()
                StatusItem.updateToolTip()
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.preferencesChanged() }
            .store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { await self?.store.refresh() } }
            .store(in: &subscriptions)

        store.start()
        loginItem.reconcileAtLaunch(wanted: store.preferences.launchAtLogin)
        DebugHooks.install()

        if firstLaunch {
            // Asked once, up front: a notification posted at the moment
            // permission is granted is not shown.
            if store.preferences.notifyExpiry { notifier.requestPermission() }
            // Show where the app lives.
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                StatusItem.openPanel()
            }
        }
    }

    private func preferencesChanged() {
        let new = Preferences(UserDefaults.standard)
        let old = store.preferences
        guard new != old else { return }
        store.update(preferences: new)
        if new.launchAtLogin != old.launchAtLogin { loginItem.set(new.launchAtLogin) }
        if new.notifyExpiry && !old.notifyExpiry { notifier.requestPermission() }
        DebugHooks.writeState()
    }

    /// The panel opened: read the CLI version and the sessions again.
    func panelOpened() {
        Task {
            await store.refreshVersion()
            await store.refresh()
            DebugHooks.writeState()
        }
    }

    private func updateMenuBarItem() {
        let shown = store.preferences.showWhenLoggedOut || store.overall() != .signedOut
        if shown != menuBarItemShown { menuBarItemShown = shown }
    }

    /// The tooltip on the menu bar item.
    func toolTip(now: Date = Date()) -> String {
        switch store.overall(now: now) {
        case .loading: return "Varlatch"
        case .cliMissing: return "Varlatch: the varlatch CLI was not found"
        case .unsupported: return "Varlatch: this varlatch CLI is too old"
        case .unavailable: return "Varlatch: the varlatch CLI did not answer"
        case .signedOut: return "Varlatch: not logged in"
        case .ok, .expiring, .expired:
            let lines = store.servers.map { server -> String in
                let host = Sessions.host(of: server.server)
                if server.health(now: now) == .expired { return "\(host): expired" }
                guard let expiresAt = server.expiresAt else { return "\(host): no expiry recorded" }
                return "\(host): " + Sessions.remaining(until: expiresAt, now: now)
            }
            return (["Varlatch"] + lines).joined(separator: "\n")
        }
    }
}
