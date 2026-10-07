import AppKit
@preconcurrency import UserNotifications
import VarlatchKit

/// Desktop notifications. Without permission the app works the same, just
/// silently.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Notifications need the bundle identifier, so a bare `swift run` has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    private(set) var authorization = "unknown"

    func install() {
        center?.delegate = self
        refreshAuthorization()
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

    static func identifier(for server: String) -> String { "expiry:" + server }

    func post(_ events: [ExpiryEvent]) {
        guard let center else { return }
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body()
            content.userInfo = ["server": event.server, "health": event.health.rawValue]
            content.threadIdentifier = "expiry"
            if event.health == .expired { content.sound = .default }
            // One per server: expired replaces expiring.
            let request = UNNotificationRequest(identifier: Self.identifier(for: event.server), content: content, trigger: nil)
            center.add(request)
        }
        DebugHooks.record("notified", events.map { "\($0.health.rawValue) \($0.server)" })
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

    // Show banners even while the panel is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Clicking a notification opens the panel.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier { StatusItem.openPanel() }
            completionHandler()
        }
    }
}
