import Foundation

/// How one stored credential is doing.
public enum SessionHealth: String, Equatable, Sendable {
    case ok
    /// Less than 20% of the credential's lifetime left.
    case expiring
    case expired
}

/// What the menu bar icon shows, worst first.
public enum OverallState: String, Equatable, Sendable {
    /// Not read yet.
    case loading
    /// No CLI where the app looks.
    case cliMissing
    /// The CLI predates `status`.
    case unsupported
    /// The CLI failed or printed something unreadable.
    case unavailable
    /// No credentials stored (or only hidden localhost ones).
    case signedOut
    case expired
    case expiring
    case ok

    /// The menu bar badge: amber while a credential is expiring, red when
    /// signed out, expired, or the CLI is unusable.
    public var badge: Badge {
        switch self {
        case .loading, .ok: return .none
        case .expiring: return .warning
        case .cliMissing, .unsupported, .unavailable, .signedOut, .expired: return .error
        }
    }

    public enum Badge: String, Sendable { case none, warning, error }

    /// The CLI cannot be used at all.
    public var cliUnusable: Bool {
        self == .cliMissing || self == .unsupported || self == .unavailable
    }
}

public extension ServerStatus {
    /// The CLI decides "expiring"; with a CLI before 0.10.0, which leaves the
    /// field out, the same rule is worked out here. A credential whose
    /// expiry has passed since the last read counts as expired.
    func health(now: Date = Date()) -> SessionHealth {
        if expired == true { return .expired }
        if let expiresAt, expiresAt <= now { return .expired }
        if reportsExpiring { return expiring == true ? .expiring : .ok }
        if let issuedAt, let expiresAt, expiresAt > issuedAt,
           expiresAt.timeIntervalSince(now) < expiresAt.timeIntervalSince(issuedAt) * 0.2 {
            return .expiring
        }
        return .ok
    }

    var host: String { Sessions.host(of: server) }
}

public enum Sessions {
    /// "vl.example.com" from "https://vl.example.com/some/path".
    public static func host(of url: String) -> String {
        var s = Substring(url)
        if let scheme = s.range(of: "://") { s = s[scheme.upperBound...] }
        if let slash = s.firstIndex(of: "/") { s = s[..<slash] }
        return String(s)
    }

    /// A local development server: `localhost` or `127.*`.
    public static func isLocalhost(_ url: String) -> Bool {
        url.lowercased().range(of: #"^[a-z][a-z0-9+.-]*://(localhost([:/]|$)|127\.)"#, options: .regularExpression) != nil
    }

    /// The servers to show: localhost ones only when asked for.
    public static func visible(_ servers: [ServerStatus], showLocalhost: Bool) -> [ServerStatus] {
        showLocalhost ? servers : servers.filter { !isLocalhost($0.server) }
    }

    /// The worst state among the shown servers.
    public static func overall(_ servers: [ServerStatus], now: Date = Date()) -> OverallState {
        guard !servers.isEmpty else { return .signedOut }
        let health = servers.map { $0.health(now: now) }
        if health.contains(.expired) { return .expired }
        if health.contains(.expiring) { return .expiring }
        return .ok
    }

    /// "3h 12m left", "12m left", or "expired".
    public static func remaining(until expiresAt: Date, now: Date = Date()) -> String {
        let seconds = expiresAt.timeIntervalSince(now)
        guard seconds > 0 else { return "expired" }
        let h = Int(seconds) / 3600
        let m = Int(seconds) % 3600 / 60
        return h > 0 ? "\(h)h \(m)m left" : "\(m)m left"
    }

    /// The line under a server's name in the panel.
    public static func detail(for server: ServerStatus, now: Date = Date()) -> String {
        if server.health(now: now) == .expired { return "Session expired" }
        guard let expiresAt = server.expiresAt else { return "Logged in, no expiry recorded" }
        return "Logged in, " + remaining(until: expiresAt, now: now)
    }
}
