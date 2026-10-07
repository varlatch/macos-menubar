import Combine
import Foundation

/// What the last release checks found, kept in `update.json` in the app's
/// Application Support directory.
public struct ReleaseCache: Codable, Equatable, Sendable {
    /// The latest release, without the "v".
    public var latest: String?
    /// The last check that got an answer.
    public var checkedAt: Date?
    /// The last check, answered or not.
    public var attemptedAt: Date?
    /// The release a notification was shown for.
    public var notified: String?

    public init(latest: String? = nil, checkedAt: Date? = nil, attemptedAt: Date? = nil, notified: String? = nil) {
        self.latest = latest
        self.checkedAt = checkedAt
        self.attemptedAt = attemptedAt
        self.notified = notified
    }

    public static func load(from url: URL) -> ReleaseCache {
        guard let data = try? Data(contentsOf: url) else { return ReleaseCache() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ReleaseCache.self, from: data)) ?? ReleaseCache()
    }

    public func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// When to ask GitHub for the latest CLI release (only with "check for new
/// CLI releases" on): when the last answer is over 12 hours old, or over an
/// hour when the panel opens, or older than the CLI installed here; never
/// more than once an hour, failed checks included.
public enum ReleaseRules {
    public static let backgroundMaxAge: TimeInterval = 12 * 3600
    public static let panelMaxAge: TimeInterval = 3600
    public static let minimumGap: TimeInterval = 3600

    public static func isStale(_ cache: ReleaseCache, current: Version?, maxAge: TimeInterval, now: Date) -> Bool {
        guard let checkedAt = cache.checkedAt, now.timeIntervalSince(checkedAt) < maxAge else { return true }
        // A release came out, and was installed, since the last check.
        if let current, let latest = cache.latest.flatMap(Version.init), current > latest { return true }
        return false
    }

    public static func shouldFetch(_ cache: ReleaseCache, current: Version?, maxAge: TimeInterval,
                                   force: Bool = false, now: Date) -> Bool {
        if force { return true }
        guard isStale(cache, current: current, maxAge: maxAge, now: now) else { return false }
        guard let attemptedAt = cache.attemptedAt else { return true }
        return now.timeIntervalSince(attemptedAt) >= minimumGap
    }

    /// The newer release, if there is one.
    public static func available(_ cache: ReleaseCache, current: Version?) -> Version? {
        guard let current, let latest = cache.latest.flatMap(Version.init), latest > current else { return nil }
        return latest
    }
}

/// The opt-in check for new CLI releases: an anonymous request to GitHub's
/// API for varlatch/varlatch's latest release.
@MainActor
public final class ReleaseChecker: ObservableObject {
    public nonisolated static let repository = "varlatch/varlatch"

    @Published public private(set) var cache: ReleaseCache
    @Published public private(set) var checking = false
    /// Called once per release that is newer than the installed CLI.
    public var onNewRelease: ((Version) -> Void)?

    private let cacheURL: URL?
    private let fetch: () async -> String?
    private let now: () -> Date

    /// - Parameters:
    ///   - cacheURL: where to keep the cache; nil keeps it in memory only.
    ///   - fetch: the latest release's tag, or nil when it cannot be read.
    public init(cacheURL: URL?, fetch: @escaping () async -> String? = ReleaseChecker.latestTag,
                now: @escaping () -> Date = Date.init) {
        self.cacheURL = cacheURL
        self.fetch = fetch
        self.now = now
        cache = cacheURL.map(ReleaseCache.load(from:)) ?? ReleaseCache()
    }

    public func available(current: Version?) -> Version? {
        ReleaseRules.available(cache, current: current)
    }

    /// Checks when the rules say so, then notifies once for a new release.
    public func check(current: Version?, maxAge: TimeInterval, force: Bool = false) async {
        guard !checking else { return }
        let started = now()
        if ReleaseRules.shouldFetch(cache, current: current, maxAge: maxAge, force: force, now: started) {
            checking = true
            cache.attemptedAt = started
            save()
            let tag = await fetch()
            checking = false
            if let tag, let version = Version(tag) {
                cache.latest = version.description
                cache.checkedAt = started
            }
        }
        if let newer = available(current: current), cache.notified != newer.description {
            cache.notified = newer.description
            onNewRelease?(newer)
        }
        save()
    }

    private func save() {
        if let cacheURL { cache.save(to: cacheURL) }
    }

    public nonisolated static func releaseURL(_ version: Version) -> URL {
        URL(string: "https://github.com/\(repository)/releases/tag/v\(version)")!
    }

    /// `GET https://api.github.com/repos/varlatch/varlatch/releases/latest`,
    /// without cookies or credentials.
    public nonisolated static func latestTag() async -> String? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Varlatch-for-macOS", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["tag_name"] as? String
    }
}
