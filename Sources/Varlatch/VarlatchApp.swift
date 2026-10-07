import SwiftUI
import VarlatchKit

@main
struct VarlatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var store = AppController.shared.store
    @ObservedObject private var controller = AppController.shared

    var body: some Scene {
        MenuBarExtra(isInserted: $controller.menuBarItemShown) {
            PanelView()
                .environmentObject(store)
                .environmentObject(controller.signIn)
                .environmentObject(controller)
        } label: {
            let state = store.overall()
            Image(nsImage: MenuBarIcon.image(for: state))
                .accessibilityLabel(MenuBarIcon.accessibilityLabel(for: state))
                .background(SettingsOpener.Capture())
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
