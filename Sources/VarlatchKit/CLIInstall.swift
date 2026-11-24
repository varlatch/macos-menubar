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

    /// Whether `path` (following symlinks) is a native macOS Mach-O program.
    public static func isNative(_ path: String) -> Bool {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let handle = FileHandle(forReadingAtPath: real) else { return false }
        defer { try? handle.close() }
        let magic = [UInt8](handle.readData(ofLength: 4))
        return magic == [0xcf, 0xfa, 0xed, 0xfe] || magic == [0xca, 0xfe, 0xba, 0xbe]
    }

    /// - Parameter path: the CLI the app runs.
    public static func kind(of path: String, fileManager: FileManager = .default) -> CLIInstall {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        // Homebrew owns copies in its Cellar or under /opt/homebrew, matching
        // how `varlatch self-update` recognizes Homebrew installs.
        if real.contains("/Cellar/") || real.contains("/opt/homebrew/") { return .homebrew }
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
