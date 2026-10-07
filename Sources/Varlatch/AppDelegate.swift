import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppController.shared.launch()
        }
        // SIGTERM (`kill`, launchd) quits like the Quit button, so a
        // sign-in the app started does not outlive it.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigterm = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppController.shared.terminate()
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
