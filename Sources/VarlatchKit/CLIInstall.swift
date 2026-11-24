import Foundation

/// How the CLI is installed, which decides how it is updated.
public enum CLIInstall: Equatable, Sendable {
    /// From the `varlatch` formula: `brew upgrade varlatch`. Its own
    /// `self-update` would replace a file Homebrew owns.
    case homebrew
    /// A release CLI: the native program (0.50 and later), or the pre-0.50
    /// single file that Node.js runs.
    case release
    /// Built in a source checkout: updated there, with git.
    case checkout
    /// Anything else.
    case custom

    /// Anchored Homebrew path prefixes (compared case-insensitively).
    public static let defaultHomebrewPrefixes = [
        "/opt/homebrew",
        "/usr/local/Homebrew",
        "/usr/local/Cellar",
        "/home/linuxbrew",
    ]

    /// Whether `path` (following symlinks) is a native macOS Mach-O program
    /// (64-bit Mach-O, universal fat, or fat64).
    public static func isNative(_ path: String) -> Bool {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let handle = FileHandle(forReadingAtPath: real) else { return false }
        defer { try? handle.close() }
        let magic = [UInt8](handle.readData(ofLength: 4))
        return magic == [0xcf, 0xfa, 0xed, 0xfe]
            || magic == [0xca, 0xfe, 0xba, 0xbe]
            || magic == [0xca, 0xfe, 0xba, 0xbf]
    }

    /// Whether `path` matches an anchored Homebrew prefix (case-insensitive).
    public static func isHomebrewPath(_ path: String, prefixes: [String] = defaultHomebrewPrefixes) -> Bool {
        let lower = path.lowercased()
        for prefix in prefixes {
            let p = prefix.lowercased().hasSuffix("/") ? String(prefix.lowercased().dropLast()) : prefix.lowercased()
            if lower == p || lower.hasPrefix(p + "/") { return true }
        }
        return false
    }

    /// Whether `path` (as invoked, or symlink-resolved) belongs to Homebrew by
    /// anchored prefix or by Homebrew's legacy wrapper marker.
    public static func isHomebrew(_ path: String, prefixes: [String] = defaultHomebrewPrefixes) -> Bool {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        for candidate in [path, real] {
            if isHomebrewPath(candidate, prefixes: prefixes) { return true }
            if hasHomebrewMarker(candidate) { return true }
        }
        return false
    }

    private static func hasHomebrewMarker(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 512), as: UTF8.self)
        return head.contains("installed with Homebrew")
    }

    /// - Parameter path: the CLI the app runs.
    public static func kind(
        of path: String,
        fileManager: FileManager = .default,
        homebrewPrefixes: [String] = defaultHomebrewPrefixes
    ) -> CLIInstall {
        if isHomebrew(path, prefixes: homebrewPrefixes) { return .homebrew }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var dir = URL(fileURLWithPath: real).deletingLastPathComponent()
        while dir.path != "/" {
            if fileManager.fileExists(atPath: dir.appendingPathComponent(".git").path) { return .checkout }
            dir.deleteLastPathComponent()
        }
        if isNative(real) { return .release }
        // The pre-0.50 single-file release build names itself in its first lines.
        if let handle = FileHandle(forReadingAtPath: real) {
            defer { try? handle.close() }
            let head = String(decoding: handle.readData(ofLength: 400), as: UTF8.self)
            if head.contains("Varlatch CLI") { return .release }
        }
        return .custom
    }

    /// Homebrew's `brew`, if installed.
    public static func brewPath(isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: isExecutable)
    }
}
