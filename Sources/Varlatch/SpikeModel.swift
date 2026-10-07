import AppKit
import ServiceManagement
import UserNotifications
import VarlatchKit

/// State for the spike: the CLI as seen from the app, notification and
/// launch-at-login status, and the icon's badge.
@MainActor
final class SpikeModel: ObservableObject {
    static let shared = SpikeModel()

    @Published var badge: MenuBarIcon.Badge = .none
    @Published var cliPath = ""
    @Published var cliVersion = ""
    @Published var cliError = ""
    @Published var notificationStatus = "unknown"
    @Published var notificationError = ""
    @Published var lastNotificationAction = ""
    @Published var loginItemStatus = ""
    @Published var loginItemError = ""

    func refreshCLI() async {
        let locator = CLILocator(override: UserDefaults.standard.string(forKey: "cliPath"))
        switch locator.resolve() {
        case .found(let path):
            cliPath = path
            let env = locator.environment(for: path, base: ProcessInfo.processInfo.environment)
            let result = await CLIProcess.run(path, ["--version"], environment: env, timeout: 15)
            cliVersion = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            cliError = result.succeeded ? "" : "exit \(result.exitCode): \(result.lastErrorLines())"
        case .overrideUnusable(let path):
            cliPath = ""
            cliError = "\(path) cannot run"
        case .notFound(let searched):
            cliPath = ""
            cliError = "not found in " + searched.joined(separator: ", ")
        }
    }

    // MARK: Notifications

    var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func refreshNotificationStatus() async {
        guard notificationsAvailable else { notificationStatus = "no bundle identifier"; return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: notificationStatus = "notDetermined"
        case .denied: notificationStatus = "denied"
        case .authorized: notificationStatus = "authorized"
        case .provisional: notificationStatus = "provisional"
        @unknown default: notificationStatus = "other"
        }
    }

    func sendTestNotification() async {
        guard notificationsAvailable else { return }
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            notificationError = granted ? "" : "not allowed"
        } catch {
            notificationError = error.localizedDescription
        }
        await refreshNotificationStatus()
        let content = UNMutableNotificationContent()
        content.title = "Varlatch"
        content.body = "Credential for vl.example.com expires soon (1h 12m left)."
        content.categoryIdentifier = AppDelegate.expiringCategory
        content.userInfo = ["server": "https://vl.example.com"]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            notificationError = error.localizedDescription
        }
        DebugHooks.writeState()
    }

    // MARK: Launch at login

    var launchMethod: LaunchAtLoginMethod { LaunchAtLoginMethod.method(forBundlePath: Bundle.main.bundlePath) }

    func refreshLoginItemStatus() {
        let status: SMAppService.Status
        switch launchMethod {
        case .loginItem:
            status = SMAppService.mainApp.status
        case .launchAgent:
            let url = LaunchAtLoginMethod.agentURL()
            status = FileManager.default.fileExists(atPath: url.path)
                ? SMAppService.statusForLegacyPlist(at: url) : .notRegistered
        }
        switch status {
        case .notRegistered: loginItemStatus = "notRegistered"
        case .enabled: loginItemStatus = "enabled"
        case .requiresApproval: loginItemStatus = "requiresApproval"
        case .notFound: loginItemStatus = "notFound"
        @unknown default: loginItemStatus = "other"
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            switch launchMethod {
            case .loginItem:
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            case .launchAgent(let appPath):
                let url = LaunchAtLoginMethod.agentURL()
                if on {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try LaunchAtLoginMethod.agentPlist(appPath: appPath).write(to: url, options: .atomic)
                } else if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            loginItemError = ""
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItemStatus()
        DebugHooks.writeState()
    }

    func state() -> [String: Any] {
        [
            "bundlePath": Bundle.main.bundlePath,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "executablePath": Bundle.main.executablePath ?? "",
            "environmentPATH": ProcessInfo.processInfo.environment["PATH"] ?? "",
            "activationPolicy": NSApp.activationPolicy() == .accessory ? "accessory" : "\(NSApp.activationPolicy().rawValue)",
            "badge": badge.rawValue,
            "cliPath": cliPath,
            "cliVersion": cliVersion,
            "cliError": cliError,
            "notificationStatus": notificationStatus,
            "notificationError": notificationError,
            "lastNotificationAction": lastNotificationAction,
            "loginItemStatus": loginItemStatus,
            "launchMethod": "\(launchMethod)",
            "loginItemError": loginItemError,
            "windows": NSApp.windows.map { "\($0.className) visible=\($0.isVisible) frame=\(NSStringFromRect($0.frame)) screen=\(NSStringFromRect($0.screen?.frame ?? .zero))" },
        ]
    }
}
