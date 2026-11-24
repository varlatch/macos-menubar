import Foundation

/// A release version such as 0.15.1, compared by its numbers. A suffix
/// (0.16.0-rc.1) is kept for display and sorts before the release, with
/// numeric dot-separated segments compared as numbers (rc.9 < rc.10).
public struct Version: Comparable, Equatable, CustomStringConvertible, Sendable {
    public static let maxLength = 64

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
        guard !s.isEmpty, s.count <= Self.maxLength else { return nil }
        if s.hasPrefix("v") { s.removeFirst() }
        var suffix = ""
        if let dash = s.firstIndex(of: "-") {
            suffix = String(s[s.index(after: dash)...])
            s = String(s[..<dash])
            guard !suffix.isEmpty,
                  !suffix.hasPrefix("."),
                  !suffix.hasSuffix("."),
                  !suffix.contains(".."),
                  suffix.unicodeScalars.allSatisfy({ Self.isSuffixScalar($0) }) else { return nil }
        }
        let rawParts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard rawParts.count == 3,
              rawParts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(Self.isDigit) }),
              let major = Int(rawParts[0]),
              let minor = Int(rawParts[1]),
              let patch = Int(rawParts[2]) else { return nil }
        self.init(major, minor, patch, suffix: suffix)
    }

    private static func isDigit(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57
    }

    private static func isSuffixScalar(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value
        return (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 46
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
        if a.suffix.isEmpty { return false }
        let pa = a.suffix.split(separator: ".")
        let pb = b.suffix.split(separator: ".")
        for (sa, sb) in zip(pa, pb) {
            if sa == sb { continue }
            let na = sa.unicodeScalars.allSatisfy(isDigit) ? UInt64(sa) : nil
            let nb = sb.unicodeScalars.allSatisfy(isDigit) ? UInt64(sb) : nil
            switch (na, nb) {
            case let (va?, vb?):
                if va != vb { return va < vb }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return sa < sb
            }
        }
        return pa.count < pb.count
    }

    /// Device sign-in (`login --start` / `--wait`) arrived in CLI 0.14.0.
    public static let deviceSignIn = Version(0, 14, 0)
    /// `self-update` arrived in CLI 0.11.0.
    public static let selfUpdate = Version(0, 11, 0)
}
