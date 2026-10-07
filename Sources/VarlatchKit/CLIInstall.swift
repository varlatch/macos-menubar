import Foundation

/// How the CLI is installed, which decides how it is updated.
public enum CLIInstall: Equatable, Sendable {
    /// From the `varlatch` formula: `brew upgrade varlatch`. Its own
    /// `self-update` would replace a file Homebrew owns.
    case homebrew
    /// The single-file release build: `varlatch self-update` (0.11.0+).
    case release
    /// Built in a source checkout: updated there, with git.
    case checkout
    /// Anything else.
    case custom

    /// - Parameter path: the CLI the app runs.
    public static func kind(of path: String, fileManager: FileManager = .default) -> CLIInstall {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if real.contains("/Cellar/varlatch/") { return .homebrew }
        var dir = URL(fileURLWithPath: real).deletingLastPathComponent()
        while dir.path != "/" {
            if fileManager.fileExists(atPath: dir.appendingPathComponent(".git").path) { return .checkout }
            dir.deleteLastPathComponent()
        }
        // The release build names itself in its first lines.
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
