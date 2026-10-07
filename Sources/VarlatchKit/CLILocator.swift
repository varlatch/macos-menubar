import Foundation

/// Finds the `varlatch` CLI and the environment to run it with.
///
/// Apps started from Finder get only `/usr/bin:/bin:/usr/sbin:/sbin` on
/// their `PATH`, so neither `varlatch` nor the `node` that the release CLI
/// starts with (`#!/usr/bin/env node`) would be found there. The CLI is
/// looked for in the usual install locations instead, and every command
/// runs with a `PATH` that includes them.
public struct CLILocator {
    /// Where the CLI is looked for, in order, when no path is set.
    public static let defaultCandidates = [
        "/opt/homebrew/bin/varlatch",
        "/usr/local/bin/varlatch",
        "~/.local/bin/varlatch",
    ]

    /// Directories put in front of the inherited `PATH`.
    public static let extraPathDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "~/.local/bin",
    ]

    public enum Resolution: Equatable {
        /// The CLI to run.
        case found(String)
        /// The path set in the settings does not exist or cannot run.
        case overrideUnusable(String)
        /// No CLI in any of these places.
        case notFound(searched: [String])
    }

    public var override: String?
    public var home: String
    public var isExecutable: (String) -> Bool

    public init(
        override: String? = nil,
        home: String = NSHomeDirectory(),
        isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.override = override
        self.home = home
        self.isExecutable = isExecutable
    }

    public func resolve() -> Resolution {
        if let raw = override?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let path = expand(raw)
            return isExecutable(path) ? .found(path) : .overrideUnusable(path)
        }
        let candidates = Self.defaultCandidates.map(expand)
        if let path = candidates.first(where: isExecutable) {
            return .found(path)
        }
        return .notFound(searched: candidates)
    }

    /// `base` with a `PATH` that starts with the CLI's own directory and the
    /// usual install locations, then whatever `base` had, without repeats.
    public func environment(for cliPath: String, base: [String: String]) -> [String: String] {
        var env = base
        let inherited = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        let cliDirectory = (cliPath as NSString).deletingLastPathComponent
        var seen = Set<String>()
        let path = ([cliDirectory] + Self.extraPathDirectories.map(expand) + inherited)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    func expand(_ path: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        return path
    }
}
