import Combine
import Foundation

/// The sessions the panel and the menu bar icon show, from polling
/// `varlatch status --json`. That command reads local files only, so polling
/// makes no network requests and never uses a stored credential.
@MainActor
public final class SessionStore: ObservableObject {
    public enum CLIState: Equatable, Sendable {
        /// Not read yet.
        case unknown
        /// Not in any of the places the app looks.
        case missing(searched: [String])
        /// The path set in Settings cannot run.
        case pathUnusable(String)
        /// Too old to have `status`.
        case unsupported
        /// It ran but failed, or printed something unreadable.
        case unavailable(String)
        case ready
    }

    /// Every stored credential, localhost ones included.
    @Published public private(set) var allServers: [ServerStatus] = []
    @Published public private(set) var cliState: CLIState = .unknown
    @Published public private(set) var cliPath: String?
    @Published public private(set) var cliVersion: Version?
    @Published public private(set) var lastRead: Date?
    @Published public private(set) var preferences: Preferences

    /// Called with each move into *expiring* or *expired*, whatever the
    /// notification setting says; the app decides whether to show them.
    public var onExpiryEvents: (([ExpiryEvent]) -> Void)?

    public let statusTimeout: TimeInterval = 15
    private let baseEnvironment: [String: String]
    private let home: String
    private let isExecutable: (String) -> Bool
    private var tracker = ExpiryTracker()
    private var timer: Timer?
    private var reading = false
    private var readQueued = false

    public init(preferences: Preferences,
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                home: String = NSHomeDirectory(),
                isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.preferences = preferences
        self.baseEnvironment = baseEnvironment
        self.home = home
        self.isExecutable = isExecutable
    }

    /// The servers to show: localhost ones only with "show localhost" on.
    public var servers: [ServerStatus] {
        Sessions.visible(allServers, showLocalhost: preferences.showLocalhost)
    }

    public func overall(now: Date = Date()) -> OverallState {
        switch cliState {
        case .unknown: return .loading
        case .missing, .pathUnusable: return .cliMissing
        case .unsupported: return .unsupported
        case .unavailable: return .unavailable
        case .ready: return Sessions.overall(servers, now: now)
        }
    }

    // MARK: Polling

    /// Reads now, then every `refreshInterval` seconds.
    public func start() {
        scheduleTimer()
        Task {
            await refreshVersion()
            await refresh()
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func update(preferences new: Preferences) {
        let old = preferences
        guard new != old else { return }
        preferences = new
        if new.refreshInterval != old.refreshInterval, timer != nil { scheduleTimer() }
        if new.cliPath != old.cliPath {
            Task {
                await refreshVersion()
                await refresh()
            }
        } else if new.showLocalhost != old.showLocalhost {
            // Shown servers changed: notify for newly shown ones.
            emitExpiryEvents()
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(preferences.refreshInterval), repeats: true) { [weak self] _ in
            // A constant: Swift 5 toolchains reject a captured `weak var` in a task.
            let store = self
            Task { @MainActor in await store?.refresh() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Reads `status --json` once. Never two at once: a refresh asked for
    /// while one runs happens right after it, so the result is never older
    /// than the request.
    public func refresh() async {
        if reading {
            readQueued = true
            return
        }
        reading = true
        repeat {
            readQueued = false
            await readStatus()
        } while readQueued
        reading = false
    }

    private func readStatus() async {
        guard let cli = resolveCLI() else {
            allServers = []
            lastRead = Date()
            return
        }
        let result = await CLIProcess.run(cli.path, ["status", "--json"], environment: cli.environment, timeout: statusTimeout)
        lastRead = Date()
        guard result.succeeded else {
            allServers = []
            cliState = Self.failureState(result)
            return
        }
        guard let document = StatusDocument.parse(result.stdout) else {
            allServers = []
            cliState = .unavailable("unreadable status output")
            return
        }
        allServers = document.servers
        cliState = .ready
        emitExpiryEvents()
    }

    private func emitExpiryEvents() {
        let events = tracker.update(servers)
        if !events.isEmpty { onExpiryEvents?(events) }
    }

    /// Why a `status --json` run failed, as the panel explains it.
    static func failureState(_ result: CLIResult) -> CLIState {
        if (result.stdout + result.stderr).contains("Usage:") { return .unsupported }
        if result.exitCode == 127, result.stderr.contains("node") {
            return .unavailable("Node.js was not found. The varlatch CLI needs Node.js 22 or newer.")
        }
        let detail = result.lastErrorLines()
        return .unavailable(detail.isEmpty ? "varlatch exited with status \(result.exitCode)" : detail)
    }

    /// Reads `varlatch --version`.
    public func refreshVersion() async {
        guard let cli = resolveCLI() else {
            cliVersion = nil
            return
        }
        let result = await CLIProcess.run(cli.path, ["--version"], environment: cli.environment, timeout: statusTimeout)
        cliVersion = result.succeeded ? Version.fromCLIOutput(result.stdout) : nil
    }

    // MARK: The CLI

    /// The CLI and the environment to run it with, or nil (with `cliState`
    /// saying why) when there is none.
    public func resolveCLI() -> (path: String, environment: [String: String])? {
        let locator = CLILocator(override: preferences.cliPath, home: home, isExecutable: isExecutable)
        switch locator.resolve() {
        case .found(let path):
            cliPath = path
            return (path, locator.environment(for: path, base: baseEnvironment))
        case .overrideUnusable(let path):
            cliPath = nil
            cliState = .pathUnusable(path)
        case .notFound(let searched):
            cliPath = nil
            cliState = .missing(searched: searched)
        }
        return nil
    }
}
