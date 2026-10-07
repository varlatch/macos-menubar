import Foundation

/// One notification for each move into *expiring* or *expired*.
public struct ExpiryEvent: Equatable, Sendable {
    public var server: String
    public var health: SessionHealth
    public var expiresAt: Date?

    public init(server: String, health: SessionHealth, expiresAt: Date?) {
        self.server = server
        self.health = health
        self.expiresAt = expiresAt
    }

    public var title: String {
        health == .expired ? "Session expired" : "Session expiring"
    }

    public func body(now: Date = Date()) -> String {
        let host = Sessions.host(of: server)
        if health == .expired { return "Credential for \(host) has expired. Log in again." }
        guard let expiresAt else { return "Credential for \(host) expires soon." }
        return "Credential for \(host) expires soon (\(Sessions.remaining(until: expiresAt, now: now)))."
    }
}

/// Remembers which state each server was last notified for, so each
/// transition notifies exactly once, as the plugin does. A server that is
/// fine again, or gone, is forgotten, so it notifies again next time.
public struct ExpiryTracker: Equatable, Sendable {
    public private(set) var notified: [String: SessionHealth] = [:]

    public init() {}

    /// The events for `servers` that were not notified yet.
    public mutating func update(_ servers: [ServerStatus], now: Date = Date()) -> [ExpiryEvent] {
        var next: [String: SessionHealth] = [:]
        var events: [ExpiryEvent] = []
        for server in servers {
            let health = server.health(now: now)
            guard health != .ok else { continue }
            next[server.server] = health
            if notified[server.server] != health {
                events.append(ExpiryEvent(server: server.server, health: health, expiresAt: server.expiresAt))
            }
        }
        notified = next
        return events
    }
}
