import Foundation
import Testing
@testable import VarlatchKit

struct AppUpdateTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-app-\(UUID().uuidString)")

    /// A minimal Varlatch.app at `path` (under the test's directory).
    @discardableResult
    func bundle(_ path: String, version: String, revision: String = "", executable: String = "binary 1") -> String {
        let app = root.appendingPathComponent(path)
        let contents = app.appendingPathComponent("Contents")
        try! FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleExecutable": "Varlatch",
            "CFBundleShortVersionString": version,
            "VarlatchSourceRevision": revision,
        ]
        try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try! executable.write(to: contents.appendingPathComponent("MacOS/Varlatch"), atomically: true, encoding: .utf8)
        return app.path
    }

    /// Points Homebrew's opt link at a version, as `brew upgrade` does.
    func link(opt version: String) throws {
        let opt = root.appendingPathComponent("opt/varlatch-menubar")
        try FileManager.default.createDirectory(at: opt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: opt)
        try FileManager.default.createSymbolicLink(atPath: opt.path, withDestinationPath: "../Cellar/varlatch-menubar/\(version)")
    }

    @Test func readsABundle() throws {
        let path = bundle("Varlatch.app", version: "0.1.0", revision: "97d7b10")
        let snapshot = try #require(BundleSnapshot.read(bundleAt: path))
        #expect(snapshot.version == "0.1.0")
        #expect(snapshot.revision == "97d7b10")
        #expect(snapshot.displayVersion == "0.1.0 (97d7b10)")
        #expect(snapshot.executableInode != nil)
        #expect(snapshot.executableModified != nil)
        #expect(BundleSnapshot.read(bundleAt: root.appendingPathComponent("Missing.app").path) == nil)
        let stable = try #require(BundleSnapshot.read(bundleAt: bundle("Stable.app", version: "0.1.0")))
        #expect(stable.revision == nil)
        #expect(stable.displayVersion == "0.1.0")
    }

    @Test func homebrewInstallsAreWatchedThroughTheOptLink() {
        #expect(AppUpdate.installedPath(forBundlePath: "/opt/homebrew/Cellar/varlatch-menubar/0.1.0/Varlatch.app") { _ in true }
                == "/opt/homebrew/opt/varlatch-menubar/Varlatch.app")
        #expect(AppUpdate.installedPath(forBundlePath: "/Applications/Varlatch.app") { _ in true }
                == "/Applications/Varlatch.app")
    }

    @Test func brewUpgrade() throws {
        let running = bundle("Cellar/varlatch-menubar/0.1.0/Varlatch.app", version: "0.1.0")
        try link(opt: "0.1.0")
        let installedPath = AppUpdate.installedPath(forBundlePath: running)
        #expect(installedPath == root.appendingPathComponent("opt/varlatch-menubar/Varlatch.app").path)
        let atLaunch = try #require(BundleSnapshot.read(bundleAt: running))
        // Nothing new yet: the link leads to the copy that runs.
        #expect(AppUpdate.pending(running: atLaunch, installed: BundleSnapshot.read(bundleAt: installedPath)) == nil)

        bundle("Cellar/varlatch-menubar/0.2.0/Varlatch.app", version: "0.2.0", executable: "binary 2")
        try link(opt: "0.2.0")
        // Cleanup removes the directory the old copy runs from.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Cellar/varlatch-menubar/0.1.0"))
        let pending = try #require(AppUpdate.pending(running: atLaunch, installed: BundleSnapshot.read(bundleAt: installedPath)))
        #expect(pending.version == "0.2.0")
        #expect(AppUpdate.title(running: atLaunch, installed: pending) == "Varlatch 0.2.0 is installed")
    }

    @Test func aNewBuildInPlace() throws {
        let path = bundle("Applications/Varlatch.app", version: "0.1.0", revision: "aaaaaaa")
        let atLaunch = try #require(BundleSnapshot.read(bundleAt: path))
        #expect(AppUpdate.pending(running: atLaunch, installed: BundleSnapshot.read(bundleAt: path)) == nil)

        // Rebuilt or reinstalled where it is: a new executable file.
        bundle("Applications/Varlatch.app", version: "0.1.0", revision: "aaaaaaa", executable: "binary 2")
        let pending = try #require(AppUpdate.pending(running: atLaunch, installed: BundleSnapshot.read(bundleAt: path)))
        #expect(AppUpdate.title(running: atLaunch, installed: pending) == "A new build of Varlatch is installed")

        bundle("Applications/Varlatch.app", version: "0.1.0", revision: "bbbbbbb", executable: "binary 3")
        let head = try #require(AppUpdate.pending(running: atLaunch, installed: BundleSnapshot.read(bundleAt: path)))
        #expect(AppUpdate.title(running: atLaunch, installed: head) == "Varlatch 0.1.0 (bbbbbbb) is installed")
    }

    @Test func uninstalledIsNotAnUpdate() throws {
        let running = bundle("Cellar/varlatch-menubar/0.1.0/Varlatch.app", version: "0.1.0")
        try link(opt: "0.1.0")
        let installedPath = AppUpdate.installedPath(forBundlePath: running)
        let atLaunch = try #require(BundleSnapshot.read(bundleAt: running))
        try FileManager.default.removeItem(at: root.appendingPathComponent("opt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Cellar"))
        #expect(AppUpdate.pending(running: atLaunch, installed: BundleSnapshot.read(bundleAt: installedPath)) == nil)
    }
}
