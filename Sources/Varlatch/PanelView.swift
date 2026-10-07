import SwiftUI

struct PanelView: View {
    @EnvironmentObject private var model: SpikeModel
    @State private var launchAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(nsImage: MenuBarIcon.mark)
                    .foregroundStyle(.secondary)
                Text("Varlatch")
                    .font(.headline)
                Spacer()
            }
            Divider()
            LabeledContent("CLI", value: model.cliPath.isEmpty ? "not found" : model.cliPath)
            LabeledContent("Version", value: model.cliVersion.isEmpty ? model.cliError : model.cliVersion)
            LabeledContent("Notifications", value: model.notificationStatus)
            LabeledContent("Login item", value: model.loginItemStatus)
            Divider()
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { on in model.setLaunchAtLogin(on) }
            HStack {
                Button("Test notification") { Task { await model.sendTestNotification() } }
                Button("Check CLI") { Task { await model.refreshCLI() } }
            }
            HStack {
                Button("Settings…") { SettingsOpener.open() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(SettingsOpener.Capture())
        .onAppear {
            launchAtLogin = model.loginItemStatus == "enabled"
            DebugHooks.writeState()
        }
    }
}
