import Foundation

/// `varlatch status --json`: the stored credentials, read offline. Every
/// server field except `server` may be null; credentials stored with
/// `--token` have no expiry metadata.
public struct StatusDocument: Decodable, Equatable, Sendable {
    public var version: Int?
    public var servers: [ServerStatus]

    public init(version: Int? = 1, servers: [ServerStatus]) {
        self.version = version
        self.servers = servers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        servers = try c.decodeIfPresent([ServerStatus].self, forKey: .servers) ?? []
    }

    enum CodingKeys: String, CodingKey { case version, servers }

    public static func parse(_ text: String) -> StatusDocument? {
        try? JSONDecoder().decode(StatusDocument.self, from: Data(text.utf8))
    }
}

public struct ServerStatus: Decodable, Equatable, Identifiable, Sendable {
    public var server: String
    public var name: String?
    public var issuedAt: Date?
    public var expiresAt: Date?
    public var credentialId: String?
    public var expired: Bool?
    /// The CLI's own "expiring" rule (from 0.10.0). `nil` either when the
    /// field is null or when an older CLI left it out; `reportsExpiring`
    /// tells the two apart.
    public var expiring: Bool?
    public var reportsExpiring: Bool
    /// From `status --probe --json` only.
    public var probe: Probe?

    public var id: String { server }

    public struct Probe: Decodable, Equatable, Sendable {
        public enum State: String, Decodable, Sendable { case valid, invalid, unreachable }
        public var state: State
        public var detail: String?

        public init(state: State, detail: String? = nil) {
            self.state = state
            self.detail = detail
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // An unknown state from a newer CLI reads as unreachable rather
            // than failing the whole document.
            state = (try? c.decode(State.self, forKey: .state)) ?? .unreachable
            detail = try c.decodeIfPresent(String.self, forKey: .detail)
        }

        enum CodingKeys: String, CodingKey { case state, detail }
    }

    public init(server: String, name: String? = nil, issuedAt: Date? = nil, expiresAt: Date? = nil,
                credentialId: String? = nil, expired: Bool? = nil, expiring: Bool? = nil,
                reportsExpiring: Bool = true, probe: Probe? = nil) {
        self.server = server
        self.name = name
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.credentialId = credentialId
        self.expired = expired
        self.expiring = expiring
        self.reportsExpiring = reportsExpiring
        self.probe = probe
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        server = try c.decode(String.self, forKey: .server)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        issuedAt = Self.date(try? c.decodeIfPresent(String.self, forKey: .issuedAt))
        expiresAt = Self.date(try? c.decodeIfPresent(String.self, forKey: .expiresAt))
        credentialId = try? c.decodeIfPresent(String.self, forKey: .credentialId)
        expired = try? c.decodeIfPresent(Bool.self, forKey: .expired)
        reportsExpiring = c.contains(.expiring)
        expiring = try? c.decodeIfPresent(Bool.self, forKey: .expiring)
        probe = try? c.decodeIfPresent(Probe.self, forKey: .probe)
    }

    enum CodingKeys: String, CodingKey {
        case server, name, issuedAt, expiresAt, credentialId, expired, expiring, probe
    }

    /// ISO 8601, with or without fractional seconds; nil for anything else.
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
