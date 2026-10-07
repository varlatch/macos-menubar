import Foundation

/// The servers seen before, newest first, so "Log in" still has a target
/// after a full logout. Kept in `servers.json` in the app's Application
/// Support directory.
public struct ServerMemory: Equatable, Sendable {
    public private(set) var servers: [String]
    public static let limit = 10

    public init(servers: [String] = []) {
        self.servers = Array(servers.prefix(Self.limit))
    }

    /// `seen` first, then the others still remembered.
    public mutating func remember(_ seen: [String]) {
        var list: [String] = []
        for server in seen + servers where !list.contains(server) { list.append(server) }
        servers = Array(list.prefix(Self.limit))
    }

    public mutating func forget(_ server: String) {
        servers.removeAll { $0 == server }
    }

    /// Where "Log in" goes with nothing stored: a remembered real deployment
    /// before a localhost one, which counts only with "show localhost" on.
    public func preferred(showLocalhost: Bool) -> String? {
        let usable = servers.filter { showLocalhost || !Sessions.isLocalhost($0) }
        return usable.first { !Sessions.isLocalhost($0) } ?? usable.first
    }

    public static func load(from url: URL) -> ServerMemory {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return ServerMemory() }
        return ServerMemory(servers: list)
    }

    public func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(servers).write(to: url, options: .atomic)
    }
}
