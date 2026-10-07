import Foundation

/// A release version such as 0.15.1, compared by its numbers. A suffix
/// (0.16.0-rc.1) is kept for display and sorts before the release.
public struct Version: Comparable, Equatable, CustomStringConvertible, Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var suffix: String

    public init(_ major: Int, _ minor: Int, _ patch: Int, suffix: String = "") {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.suffix = suffix
    }

    /// "0.15.1", "v0.15.1", or "0.16.0-rc.1"; nil for anything else.
    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") { s.removeFirst() }
        var suffix = ""
        if let dash = s.firstIndex(of: "-") {
            suffix = String(s[s.index(after: dash)...])
            s = String(s[..<dash])
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, let major = parts[0], let minor = parts[1], let patch = parts[2] else { return nil }
        self.init(major, minor, patch, suffix: suffix)
    }

    /// The version in `varlatch --version` output: "varlatch 0.15.1 (migration 26)".
    public static func fromCLIOutput(_ output: String) -> Version? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let words = line.split(separator: " ")
        guard words.count >= 2, words[0] == "varlatch" else { return nil }
        return Version(String(words[1]))
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (suffix.isEmpty ? "" : "-\(suffix)")
    }

    public static func < (a: Version, b: Version) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        // A pre-release comes before its release.
        if a.suffix.isEmpty != b.suffix.isEmpty { return !a.suffix.isEmpty }
        return a.suffix < b.suffix
    }

    /// Device sign-in (`login --start` / `--wait`) arrived in CLI 0.14.0.
    public static let deviceSignIn = Version(0, 14, 0)
    /// `self-update` arrived in CLI 0.11.0.
    public static let selfUpdate = Version(0, 11, 0)
}
