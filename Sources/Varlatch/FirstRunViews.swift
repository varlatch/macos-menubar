import SwiftUI
import VarlatchKit

/// No CLI where the app looks: what it is for, and installing it with
/// Homebrew.
@MainActor
struct InstallCLIView: View {
    let searched: [String]
    @EnvironmentObject private var controller: AppController
    @State private var copied = false

    var body: some View {
        let brew = CLIInstall.brewPath()
        MessageView(symbol: "terminal", title: "The varlatch CLI is not installed",
                    detail: "Varlatch for macOS shows and renews the sessions of the varlatch CLI. "
                        + (brew == nil ? "Install Homebrew first, then the CLI:" : "Install it with Homebrew:")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppController.installCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                HStack {
                    if brew != nil {
                        Button("Install in Terminal") { controller.installCLI() }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Get Homebrew") { controller.open("https://brew.sh") }
                    }
                    Button(copied ? "Copied" : "Copy Command") {
                        controller.copy(AppController.installCommand)
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copied = false
                        }
                    }
                }
                .controlSize(.small)
                Text("Looked for it in " + PanelView.list(searched.map(PanelView.abbreviated))
                     + ". Installed somewhere else? Set its path in Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The server's address, for the first sign-in or another server. Connect
/// starts the usual browser sign-in.
@MainActor
struct ConnectView: View {
    /// Something to go back to, so the form gets a Cancel.
    let cancellable: Bool
    let done: () -> Void
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var store: SessionStore
    @State private var address = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.servers.isEmpty ? "Connect to your Varlatch server" : "Connect another server")
                .font(.system(size: 13, weight: .medium))
            HStack(spacing: 6) {
                TextField("varlatch.example.com", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(connect)
                    .onChange(of: address) { _ in error = nil }
                    .accessibilityLabel("Server address")
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                if cancellable {
                    Button("Cancel", action: done)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .controlSize(.small)
            Text(error ?? "Your browser opens for the passkey sign-in.")
                .font(.system(size: 11))
                .foregroundStyle(error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .onAppear { focused = true }
    }

    private func connect() {
        guard let server = ServerAddress.normalize(address) else {
            error = "Give the server's address, such as varlatch.example.com"
            return
        }
        store.remember([server])
        controller.signIn(to: server)
        address = ""
        done()
    }
}

/// A newer CLI release (with release checks on): how to update this CLI.
@MainActor
struct UpdateView: View {
    let version: Version
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        let update = controller.update(to: version)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CLI \(version.description) is available")
                        .font(.system(size: 12, weight: .medium))
                    Group {
                        switch update {
                        case .homebrew: Text("Update: run ") + Text("brew upgrade varlatch").font(.system(size: 11, design: .monospaced))
                        case .selfUpdate: Text("Update: run ") + Text("varlatch self-update").font(.system(size: 11, design: .monospaced))
                        case .manual: Text("Update it the way you installed it.")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Release Notes") { NSWorkspace.shared.open(ReleaseChecker.releaseURL(version)) }
                    if update != .manual {
                        Button("Update in Terminal") { controller.updateCLI(to: version) }
                    }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// A newer copy of the app was installed while it runs (after `brew
/// upgrade`): restart to use it.
@MainActor
struct AppUpdateView: View {
    let title: String
    @EnvironmentObject private var controller: AppController
    /// Restarting would cancel a sign-in under way.
    @EnvironmentObject private var signIn: SignInController

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 15))
                .foregroundStyle(.green)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    Text(signIn.isIdle ? "Restart Varlatch to use it." : "Restart once the sign-in has finished.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Button("Restart") { controller.restartToUpdate() }
                    .controlSize(.small)
                    .disabled(!signIn.isIdle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
