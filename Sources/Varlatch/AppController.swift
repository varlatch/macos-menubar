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
    let signIn: SignInController
    let releases = ReleaseChecker(cacheURL: AppSupport.directory.appendingPathComponent("update.json"))
    let notifier = Notifier()
    let loginItem = LoginItemController()
    /// Servers with a logout running.
    @Published private(set) var loggingOut: Set<String> = []
    /// A newer copy of the app, installed while this one runs.
    @Published private(set) var installedUpdate: BundleSnapshot?
    /// This app as it was on disk when it started; nil for a bare build
    /// without a bundle.
    let runningApp = BundleSnapshot.read(bundleAt: Bundle.main.bundlePath)
    private var notifiedUpdate: BundleSnapshot?
    private var subscriptions: Set<AnyCancellable> = []
    private var releaseTimer: Timer?
    private var installTimer: Timer?

    private init() {
        UserDefaults.standard.register(defaults: Preferences.registrationDefaults)
        let store = SessionStore(preferences: Preferences(UserDefaults.standard), stateDirectory: AppSupport.directory)
        self.store = store
        signIn = SignInController { store.resolveCLI() }
    }

    func launch() {
        let firstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunched")
        UserDefaults.standard.set(true, forKey: "hasLaunched")

        notifier.install()
        store.onExpiryEvents = { [weak self] events in
            guard let self, self.store.preferences.notifyExpiry else { return }
            self.notifier.post(events, device: self.deviceSignIn)
        }
        // A server that is fine again, or gone, takes its expiry
        // notification with it.
        store.$allServers
            .sink { [weak self] servers in self?.notifier.withdrawResolved(servers) }
            .store(in: &subscriptions)
        signIn.onOutcome = { [weak self] outcome in
            guard let self else { return }
            if case .signedIn(let server, _) = outcome { self.store.remember([server]) }
            self.notifier.post(outcome, device: self.deviceSignIn)
        }
        signIn.onFinished = { [weak self] in
            let store = self?.store
            Task { await store?.refresh() }
        }
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
            .sink { [weak self] _ in
                let store = self?.store
                Task { await store?.refresh() }
                self?.checkInstalledUpdate()
            }
            .store(in: &subscriptions)

        releases.onNewRelease = { [weak self] version in
            guard let self else { return }
            self.notifier.postRelease(version, current: self.store.cliVersion, update: self.update(to: version))
        }
        releases.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        // A newly installed CLI can make the cached release old news.
        store.$cliVersion
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.checkReleases(maxAge: ReleaseRules.backgroundMaxAge) }
            .store(in: &subscriptions)

        store.start()
        loginItem.reconcileAtLaunch(wanted: store.preferences.launchAtLogin)
        // Hourly; the rules decide whether that is a request.
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            let controller = self
            Task { @MainActor in controller?.checkReleases(maxAge: ReleaseRules.backgroundMaxAge) }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseTimer = timer
        // A look at the installed copy is two file reads; once a minute.
        let installTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            let controller = self
            Task { @MainActor in controller?.checkInstalledUpdate() }
        }
        installTimer.tolerance = 10
        RunLoop.main.add(installTimer, forMode: .common)
        self.installTimer = installTimer
        Task {
            // After the first read of the CLI version.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            checkReleases(maxAge: ReleaseRules.backgroundMaxAge)
        }
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
        if new.checkUpdates && !old.checkUpdates { checkReleases(maxAge: ReleaseRules.backgroundMaxAge) }
        DebugHooks.writeState()
    }

    // MARK: Actions

    /// Signs in to `server` in the browser (renewing is the same). While a
    /// sign-in waits, opens its link again instead.
    func signIn(to server: String) {
        if let link = signIn.signIn(server: server, ttlArguments: store.preferences.ttlArguments) {
            open(link)
        }
    }

    /// Device sign-in (`login --start` / `--wait`) arrived in CLI 0.14.0.
    var deviceSignIn: Bool {
        store.cliVersion.map { $0 >= Version.deviceSignIn } ?? false
    }

    /// Signs in to `server` from another device: an address and a code to
    /// approve on any device, such as a phone. Takes over a browser sign-in
    /// still waiting.
    func signInFromAnotherDevice(to server: String) {
        guard deviceSignIn else { return }
        Task { await signIn.signInFromAnotherDevice(server: server, ttlArguments: store.preferences.ttlArguments) }
    }

    func cancelSignIn() {
        signIn.cancel()
    }

    func logout(_ server: String) {
        guard !loggingOut.contains(server) else { return }
        loggingOut.insert(server)
        Task {
            let result = await store.logout(server: server)
            loggingOut.remove(server)
            notifier.postLogout(server: server, message: result.message, succeeded: result.succeeded)
        }
    }

    func verify() {
        Task { await store.verify() }
    }

    /// The server's dashboard is the server's own address.
    func openDashboard(_ server: String? = nil) {
        guard let server = server ?? store.knownServer else { return }
        open(server)
    }

    func open(_ address: String) {
        guard let url = URL(string: address), url.scheme == "https" || url.scheme == "http" else { return }
        NSWorkspace.shared.open(url)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The app is quitting: a sign-in it started must not outlive it.
    func terminate() {
        signIn.cancel(quietly: true)
    }

    /// The panel opened: read the CLI version and the sessions again, and
    /// with release checks on, check again when the last one is over an
    /// hour old.
    func panelOpened() {
        checkInstalledUpdate()
        Task {
            await store.refreshVersion()
            await store.refresh()
            checkReleases(maxAge: ReleaseRules.panelMaxAge)
            DebugHooks.writeState()
        }
    }

    // MARK: The app's own updates

    /// Where the installed copy of this app is: Homebrew's opt link, or
    /// this bundle.
    var installedAppPath: String {
        AppUpdate.installedPath(forBundlePath: Bundle.main.bundlePath)
    }

    /// Looks for a newer copy of the app installed while this one runs,
    /// such as after `brew upgrade`, and notifies once per copy.
    func checkInstalledUpdate() {
        guard let runningApp else { return }
        let pending = AppUpdate.pending(running: runningApp, installed: BundleSnapshot.read(bundleAt: installedAppPath))
        if pending != installedUpdate { installedUpdate = pending }
        if let pending, pending != notifiedUpdate {
            notifiedUpdate = pending
            notifier.postAppUpdate(title: AppUpdate.title(running: runningApp, installed: pending))
        }
    }

    /// Quits, and opens the installed copy once this one is gone. With a
    /// sign-in under way, shows the panel instead.
    func restartToUpdate() {
        guard installedUpdate != nil else { return }
        guard signIn.isIdle else {
            StatusItem.openPanel()
            return
        }
        // A helper outlives the app: it waits (at most 10 seconds) for this
        // process to exit, then opens the installed copy.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            #"i=0; while kill -0 "$1" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; exec /usr/bin/open "$2""#,
            "varlatch-restart", String(ProcessInfo.processInfo.processIdentifier), installedAppPath,
        ]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            NSLog("Varlatch: cannot restart: \(error)")
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: The CLI and its updates

    /// The command that installs the CLI with Homebrew.
    static let installCommand = "brew install varlatch/tap/varlatch"

    /// How the CLI the app runs is installed.
    var cliInstall: CLIInstall? {
        store.cliPath.map { CLIInstall.kind(of: $0) }
    }

    /// Installs the CLI with Homebrew, in Terminal.
    func installCLI() {
        guard let brew = CLIInstall.brewPath() else { return }
        TerminalCommand.run(title: "Installing the Varlatch CLI with Homebrew",
                            command: "\(TerminalCommand.shellQuoted(brew)) install varlatch/tap/varlatch")
    }

    /// `brew upgrade varlatch`, in Terminal.
    func upgradeWithHomebrew() {
        guard let brew = CLIInstall.brewPath() else { return }
        TerminalCommand.run(title: "Updating the Varlatch CLI with Homebrew",
                            command: "\(TerminalCommand.shellQuoted(brew)) upgrade varlatch")
    }

    /// Checks for a newer CLI release, with "check for new CLI releases" on.
    func checkReleases(maxAge: TimeInterval) {
        guard store.preferences.checkUpdates else { return }
        Task { await releases.check(current: store.cliVersion, maxAge: maxAge) }
    }

    /// A newer CLI release, with release checks on.
    var availableRelease: Version? {
        store.preferences.checkUpdates ? releases.available(current: store.cliVersion) : nil
    }

    enum Update: Equatable {
        /// `brew upgrade varlatch`.
        case homebrew
        /// `varlatch self-update <version>` (CLI 0.11.0 and newer).
        case selfUpdate
        /// Release notes only: updated the way it was installed.
        case manual
    }

    func update(to version: Version) -> Update {
        switch cliInstall {
        case .homebrew: return .homebrew
        case .release:
            return (store.cliVersion.map { $0 >= Version.selfUpdate } ?? false) ? .selfUpdate : .manual
        default: return .manual
        }
    }

    /// Updates the CLI in Terminal: Homebrew's, or the release build's own
    /// self-update, which shows what it checked and asks before replacing
    /// anything.
    func updateCLI(to version: Version) {
        switch update(to: version) {
        case .homebrew:
            upgradeWithHomebrew()
        case .selfUpdate:
            guard let path = store.cliPath else { return }
            let directory = (path as NSString).deletingLastPathComponent
            let quoted = TerminalCommand.shellQuoted(path)
            // sudo resets PATH, so the release CLI's `env node` would not
            // find node: name it.
            let command = FileManager.default.isWritableFile(atPath: directory)
                ? "\(quoted) self-update \(version)"
                : "sudo \"$(command -v node)\" \(quoted) self-update \(version)"
            TerminalCommand.run(title: "Updating the Varlatch CLI", command: command)
        case .manual:
            NSWorkspace.shared.open(ReleaseChecker.releaseURL(version))
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
