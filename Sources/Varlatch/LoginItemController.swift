import AppKit
import ServiceManagement
import VarlatchKit

/// Launch at login. A Homebrew install uses a LaunchAgent that opens the
/// stable opt link, since `brew upgrade` removes the versioned directory the
/// app runs from; anywhere else the app is a login item (`SMAppService`).
@MainActor
final class LoginItemController {
    private(set) var lastError = ""

    var method: LaunchAtLoginMethod { LaunchAtLoginMethod.method(forBundlePath: Bundle.main.bundlePath) }

    /// Installed with Homebrew or in an Applications folder, rather than a
    /// build in a checkout, which should not become a login item by itself.
    var isInstalled: Bool {
        if case .launchAgent = method { return true }
        return Bundle.main.bundlePath.contains("/Applications/")
    }

    /// At launch, make the system match the setting (on by default), but
    /// leave a development build alone.
    func reconcileAtLaunch(wanted: Bool) {
        guard isInstalled else { return }
        set(wanted)
    }

    func set(_ wanted: Bool) {
        do {
            switch method {
            case .loginItem:
                let service = SMAppService.mainApp
                if wanted, service.status == .notRegistered || service.status == .notFound {
                    try service.register()
                } else if !wanted, service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                }
            case .launchAgent(let appPath):
                let url = LaunchAtLoginMethod.agentURL()
                let plist = LaunchAtLoginMethod.agentPlist(appPath: appPath)
                if wanted {
                    if (try? Data(contentsOf: url)) != plist {
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                                withIntermediateDirectories: true)
                        try plist.write(to: url, options: .atomic)
                    }
                } else if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                    Self.bootout()
                }
            }
            lastError = ""
        } catch {
            lastError = error.localizedDescription
        }
    }

    enum Status: String { case on, off, needsApproval }

    var status: Status {
        switch method {
        case .loginItem:
            switch SMAppService.mainApp.status {
            case .enabled: return .on
            case .requiresApproval: return .needsApproval
            default: return .off
            }
        case .launchAgent:
            let url = LaunchAtLoginMethod.agentURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return .off }
            // A new agent reads as not found until it has been loaded once.
            return SMAppService.statusForLegacyPlist(at: url) == .requiresApproval ? .needsApproval : .on
        }
    }

    /// Unloads the agent if a login loaded it; nothing to do otherwise.
    private static func bootout() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(LaunchAtLoginMethod.agentLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
