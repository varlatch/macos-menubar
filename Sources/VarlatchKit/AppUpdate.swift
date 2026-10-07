import Foundation

/// An app bundle as it is on disk: the version it says it is, and the
/// executable file it holds. Read from the files, never from `Bundle`, which
/// caches what it read first.
public struct BundleSnapshot: Equatable, Sendable {
    /// With symbolic links resolved.
    public var path: String
    public var version: String?
    /// The source revision `scripts/bundle.sh` records, when built from git.
    public var revision: String?
    public var executableInode: UInt64?
    public var executableModified: Date?

    public init(path: String, version: String?, revision: String? = nil,
                executableInode: UInt64? = nil, executableModified: Date? = nil) {
        self.path = path
        self.version = version
        self.revision = revision
        self.executableInode = executableInode
        self.executableModified = executableModified
    }

    /// Nil when there is no app bundle at `path`.
    public static func read(bundleAt path: String, fileManager: FileManager = .default) -> BundleSnapshot? {
        let bundle = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String,
              let attributes = try? fileManager.attributesOfItem(
                  atPath: bundle.appendingPathComponent("Contents/MacOS/\(executable)").path) else { return nil }
        return BundleSnapshot(
            path: bundle.path,
            version: info["CFBundleShortVersionString"] as? String,
            revision: (info["VarlatchSourceRevision"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            executableInode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            executableModified: attributes[.modificationDate] as? Date)
    }

    /// "0.2.0", or "0.2.0 (abc1234)" for a build from git.
    public var displayVersion: String {
        (version ?? "?") + (revision.map { " (\($0))" } ?? "")
    }
}

/// Noticing that a newer copy of the app was installed while it runs. A
/// running app keeps running its old code after `brew upgrade` (which may
/// even remove the directory it runs from) until it is opened again.
public enum AppUpdate {
    /// Where the installed copy of the app is: Homebrew's `opt` link for a
    /// Homebrew install, since `brew upgrade` installs into a new versioned
    /// directory and moves the link; anywhere else, the bundle itself, which
    /// an update replaces in place.
    public static func installedPath(forBundlePath bundlePath: String,
                                     exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        if case .launchAgent(let optPath) = LaunchAtLoginMethod.method(forBundlePath: bundlePath, exists: exists) {
            return optPath
        }
        return bundlePath
    }

    /// The installed copy, when it is not the one running: a newer version,
    /// or a new build of the same one. Nil when it is the same, or when
    /// there is no installed copy (the app was uninstalled).
    public static func pending(running: BundleSnapshot, installed: BundleSnapshot?) -> BundleSnapshot? {
        guard let installed, installed != running else { return nil }
        return installed
    }

    /// "Varlatch 0.2.0 is installed", or for a new build of the same
    /// version, "A new build of Varlatch is installed".
    public static func title(running: BundleSnapshot, installed: BundleSnapshot) -> String {
        installed.displayVersion == running.displayVersion
            ? "A new build of Varlatch is installed"
            : "Varlatch \(installed.displayVersion) is installed"
    }
}
