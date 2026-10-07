import Foundation

/// The app's settings, stored in its user defaults
/// (`defaults read com.varlatch.menubar`).
public struct Preferences: Equatable, Sendable {
    public enum Key {
        public static let refreshInterval = "refreshInterval"
        public static let cliPath = "cliPath"
        public static let notifyExpiry = "notifyExpiry"
        public static let showWhenLoggedOut = "showWhenLoggedOut"
        public static let showLocalhost = "showLocalhost"
        public static let sessionHours = "sessionHours"
        public static let checkUpdates = "checkUpdates"
        public static let launchAtLogin = "launchAtLogin"
    }

    public static let defaultRefreshInterval = 30
    public static let minimumRefreshInterval = 15

    /// Seconds between status reads, 15 or more.
    public var refreshInterval: Int
    /// The CLI to run; empty finds it automatically.
    public var cliPath: String
    public var notifyExpiry: Bool
    /// Off: no menu bar icon while no credentials are stored.
    public var showWhenLoggedOut: Bool
    public var showLocalhost: Bool
    /// How long a new sign-in lasts: 0 for the server's default, else 1 to 24.
    public var sessionHours: Int
    public var checkUpdates: Bool
    public var launchAtLogin: Bool

    public init(refreshInterval: Int = defaultRefreshInterval, cliPath: String = "", notifyExpiry: Bool = true,
                showWhenLoggedOut: Bool = true, showLocalhost: Bool = false, sessionHours: Int = 0,
                checkUpdates: Bool = false, launchAtLogin: Bool = true) {
        self.refreshInterval = max(Self.minimumRefreshInterval, refreshInterval)
        self.cliPath = cliPath
        self.notifyExpiry = notifyExpiry
        self.showWhenLoggedOut = showWhenLoggedOut
        self.showLocalhost = showLocalhost
        self.sessionHours = (1...24).contains(sessionHours) ? sessionHours : 0
        self.checkUpdates = checkUpdates
        self.launchAtLogin = launchAtLogin
    }

    /// The defaults for keys never set, for `UserDefaults.register`.
    public static let registrationDefaults: [String: Any] = [
        Key.refreshInterval: defaultRefreshInterval,
        Key.cliPath: "",
        Key.notifyExpiry: true,
        Key.showWhenLoggedOut: true,
        Key.showLocalhost: false,
        Key.sessionHours: 0,
        Key.checkUpdates: false,
        Key.launchAtLogin: true,
    ]

    public init(_ defaults: UserDefaults) {
        func bool(_ key: String) -> Bool {
            (defaults.object(forKey: key) as? Bool) ?? (Self.registrationDefaults[key] as? Bool) ?? false
        }
        func int(_ key: String) -> Int {
            (defaults.object(forKey: key) as? Int) ?? (Self.registrationDefaults[key] as? Int) ?? 0
        }
        self.init(refreshInterval: int(Key.refreshInterval),
                  cliPath: defaults.string(forKey: Key.cliPath) ?? "",
                  notifyExpiry: bool(Key.notifyExpiry),
                  showWhenLoggedOut: bool(Key.showWhenLoggedOut),
                  showLocalhost: bool(Key.showLocalhost),
                  sessionHours: int(Key.sessionHours),
                  checkUpdates: bool(Key.checkUpdates),
                  launchAtLogin: bool(Key.launchAtLogin))
    }

    /// `--ttl <seconds>` for every sign-in the app starts, or nothing for
    /// the server's default.
    public var ttlArguments: [String] {
        sessionHours > 0 ? ["--ttl", String(sessionHours * 3600)] : []
    }
}
