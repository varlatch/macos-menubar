import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static let expiringCategory = "expiring"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            let renew = UNNotificationAction(identifier: "renew", title: "Renew now")
            let device = UNNotificationAction(identifier: "device", title: "Another device")
            center.setNotificationCategories([
                UNNotificationCategory(identifier: Self.expiringCategory, actions: [renew, device], intentIdentifiers: []),
            ])
        }
        DebugHooks.install()
        Task { @MainActor in
            let model = SpikeModel.shared
            await model.refreshCLI()
            await model.refreshNotificationStatus()
            model.refreshLoginItemStatus()
            DebugHooks.writeState()
        }
    }

    // Show banners even while the panel is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        Task { @MainActor in
            SpikeModel.shared.lastNotificationAction = action
            DebugHooks.writeState()
            completionHandler()
        }
    }
}
