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
        static let outcome = "outcome"
    }

    enum Action {
        static let renew = "renew"
        static let login = "login"
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
        return [
            UNNotificationCategory(identifier: Category.expiring, actions: [renew], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.expired, actions: [login], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.outcome, actions: [], intentIdentifiers: []),
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

    func post(_ events: [ExpiryEvent]) {
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body()
            content.categoryIdentifier = event.health == .expired ? Category.expired : Category.expiring
            content.userInfo = ["server": event.server]
            content.threadIdentifier = "expiry"
            if event.health == .expired { content.sound = .default }
            // One per server: expired replaces expiring.
            deliver(Self.expiryIdentifier(for: event.server), content)
        }
        DebugHooks.record("notified", events.map { "\($0.health.rawValue) \($0.server)" })
    }

    func post(_ outcome: SignInController.Outcome) {
        let content = UNMutableNotificationContent()
        switch outcome {
        case .signedIn: content.title = "Logged in"
        case .cancelled: content.title = "Sign-in cancelled"
        case .failed:
            content.title = "Sign-in failed"
            content.sound = .default
        }
        content.body = outcome.message
        content.categoryIdentifier = Category.outcome
        content.userInfo = ["server": outcome.server]
        deliver("signin:" + outcome.server, content)
        if case .signedIn = outcome { withdraw(Self.expiryIdentifier(for: outcome.server)) }
        DebugHooks.record("notified", [outcome.message])
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
        Task { @MainActor in
            DebugHooks.record("answered", [action + " " + (server ?? "")])
            let controller = AppController.shared
            switch action {
            case Action.renew, Action.login:
                if let server { controller.signIn(to: server) }
            case UNNotificationDefaultActionIdentifier:
                StatusItem.openPanel()
            default:
                break
            }
            completionHandler()
        }
    }
}
