import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppController.shared.launch()
        }
    }

    /// Opening the app again (from Finder, Spotlight, or Launchpad) opens the
    /// panel, or Settings while the menu bar item is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if AppController.shared.menuBarItemShown {
                StatusItem.openPanel()
            } else {
                SettingsOpener.open()
            }
        }
        return false
    }
}
