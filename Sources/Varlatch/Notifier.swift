import AppKit
@preconcurrency import UserNotifications
import VarlatchKit

/// Desktop notifications: expiry, with a button to renew or log in, and the
/// outcome of sign-ins and logouts. Without permission the app works the
/// same, just silently.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Category {
        static let expiring = "expiring"
        static let expired = "expired"
        /// With an Another Device button (CLI 0.14.0 and newer).
        static let expiringDevice = "expiring-device"
        static let expiredDevice = "expired-device"
        static let failedDevice = "failed-device"
        static let release = "release"
        static let releaseUpdate = "release-update"
        static let appUpdate = "app-update"
        static let outcome = "outcome"
    }

    enum Action {
        static let renew = "renew"
        static let login = "login"
        static let device = "device"
        static let update = "update"
        static let notes = "notes"
        static let restart = "restart"
    }

    /// Notifications need the bundle identifier, so a bare `swift run` has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    private(set) var authorization = "unknown"

    func install() {
        guard let center else { return }
        center.delegate = self
        center.setNotificationCategories(categories())
        refreshAuthorization()
    }

    private func categories() -> Set<UNNotificationCategory> {
        let renew = UNNotificationAction(identifier: Action.renew, title: "Renew Now")
        let login = UNNotificationAction(identifier: Action.login, title: "Log In")
        let another = UNNotificationAction(identifier: Action.device, title: "Another Device")
        let useAnother = UNNotificationAction(identifier: Action.device, title: "Use Another Device")
        func category(_ id: String, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
            UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [])
        }
        return [
            category(Category.expiring, [renew]),
            category(Category.expired, [login]),
            category(Category.expiringDevice, [renew, another]),
            category(Category.expiredDevice, [login, another]),
            category(Category.failedDevice, [useAnother]),
            category(Category.appUpdate, [UNNotificationAction(identifier: Action.restart, title: "Restart Now")]),
            category(Category.release, [UNNotificationAction(identifier: Action.notes, title: "Release Notes")]),
            category(Category.releaseUpdate, [UNNotificationAction(identifier: Action.update, title: "Update"),
                                              UNNotificationAction(identifier: Action.notes, title: "Release Notes")]),
            category(Category.outcome, []),
        ]
    }

    func requestPermission() {
        guard let center else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in self.refreshAuthorization() }
        }
    }

    func refreshAuthorization() {
        center?.getNotificationSettings { settings in
            let status: String
            switch settings.authorizationStatus {
            case .notDetermined: status = "notDetermined"
            case .denied: status = "denied"
            case .authorized: status = "authorized"
            case .provisional: status = "provisional"
            @unknown default: status = "other"
            }
            Task { @MainActor in self.authorization = status }
        }
    }

    // MARK: Posting

    static func expiryIdentifier(for server: String) -> String { "expiry:" + server }

    /// `device`: the CLI can sign in from another device.
    func post(_ events: [ExpiryEvent], device: Bool) {
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body()
            content.categoryIdentifier = event.health == .expired
                ? (device ? Category.expiredDevice : Category.expired)
                : (device ? Category.expiringDevice : Category.expiring)
            content.userInfo = ["server": event.server]
            content.threadIdentifier = "expiry"
            if event.health == .expired { content.sound = .default }
            // One per server: expired replaces expiring.
            deliver(Self.expiryIdentifier(for: event.server), content)
        }
        DebugHooks.record("notified", events.map {
            "[\($0.health == .expired ? (device ? Category.expiredDevice : Category.expired) : (device ? Category.expiringDevice : Category.expiring))] \($0.health.rawValue) \($0.server)"
        })
    }

    /// `device`: the CLI can sign in from another device, which a failed
    /// browser sign-in then offers.
    func post(_ outcome: SignInController.Outcome, device: Bool) {
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = Category.outcome
        switch outcome {
        case .signedIn:
            content.title = "Logged in"
        case .cancelled:
            content.title = "Sign-in cancelled"
        case .denied:
            content.title = "Sign-in denied"
            content.sound = .default
        case .codeExpired:
            content.title = "Sign-in code expired"
            content.sound = .default
        case .failed(_, _, let browser):
            content.title = "Sign-in failed"
            content.sound = .default
            if browser, device { content.categoryIdentifier = Category.failedDevice }
        }
        content.body = outcome.message
        content.userInfo = ["server": outcome.server]
        deliver("signin:" + outcome.server, content)
        if case .signedIn = outcome { withdraw(Self.expiryIdentifier(for: outcome.server)) }
        DebugHooks.record("notified", ["[\(content.categoryIdentifier)] \(outcome.message)"])
    }

    func postLogout(server: String, message: String, succeeded: Bool) {
        let content = UNMutableNotificationContent()
        content.title = succeeded ? "Logged out" : "Log out failed"
        content.body = message
        content.categoryIdentifier = Category.outcome
        if !succeeded { content.sound = .default }
        deliver("logout:" + server, content)
        DebugHooks.record("notified", [message])
    }

    /// A newer CLI release, once per release.
    func postRelease(_ version: Version, current: Version?, update: AppController.Update) {
        let content = UNMutableNotificationContent()
        content.title = "Varlatch CLI \(version) is available"
        let have = current.map { " (you have \($0))" } ?? ""
        switch update {
        case .homebrew:
            content.body = "Update with Homebrew: brew upgrade varlatch\(have)."
            content.categoryIdentifier = Category.releaseUpdate
        case .selfUpdate:
            content.body = "Update with varlatch self-update\(have)."
            content.categoryIdentifier = Category.releaseUpdate
        case .manual:
            content.body = "A new release of the CLI is out\(have)."
            content.categoryIdentifier = Category.release
        }
        content.userInfo = ["version": version.description]
        deliver("release:" + version.description, content)
        DebugHooks.record("notified", ["[\(content.categoryIdentifier)] \(content.title)"])
    }

    /// A newer copy of the app is installed: restart to use it.
    func postAppUpdate(title: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "Restart Varlatch to use it."
        content.categoryIdentifier = Category.appUpdate
        deliver("app-update", content)
        DebugHooks.record("notified", ["[\(content.categoryIdentifier)] \(title)"])
    }

    private func deliver(_ identifier: String, _ content: UNNotificationContent) {
        center?.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    private func withdraw(_ identifier: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Removes the expiry notifications of servers that are fine again or gone.
    func withdrawResolved(_ servers: [ServerStatus]) {
        guard let center else { return }
        let stillBad = Set(servers.filter { $0.health() != .ok }.map(\.server))
        center.getDeliveredNotifications { delivered in
            let resolved = delivered.map(\.request.identifier)
                .filter { $0.hasPrefix("expiry:") && !stillBad.contains(String($0.dropFirst("expiry:".count))) }
            if !resolved.isEmpty { center.removeDeliveredNotifications(withIdentifiers: resolved) }
        }
    }

    // MARK: Answers

    // Show banners even while the panel is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let server = response.notification.request.content.userInfo["server"] as? String
        let version = (response.notification.request.content.userInfo["version"] as? String).flatMap(Version.init)
        Task { @MainActor in
            DebugHooks.record("answered", [action + " " + (server ?? "")])
            let controller = AppController.shared
            switch action {
            case Action.renew, Action.login:
                if let server { controller.signIn(to: server) }
            case Action.device:
                if let server { controller.signInFromAnotherDevice(to: server) }
            case Action.restart:
                controller.restartToUpdate()
            case Action.update:
                if let version { controller.updateCLI(to: version) }
            case Action.notes:
                if let version { NSWorkspace.shared.open(ReleaseChecker.releaseURL(version)) }
            case UNNotificationDefaultActionIdentifier:
                StatusItem.openPanel()
            default:
                break
            }
            completionHandler()
        }
    }
}
