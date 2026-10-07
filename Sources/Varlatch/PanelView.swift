import SwiftUI
import VarlatchKit

/// The panel under the menu bar icon: one row per session with a live
/// countdown and its actions, or what stands in the way. The only network
/// requests are the ones these buttons start.
@MainActor
struct PanelView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var signIn: SignInController
    @EnvironmentObject private var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // Countdowns move on their own between reads.
            TimelineView(.periodic(from: .now, by: 10)) { context in
                VStack(alignment: .leading, spacing: 0) {
                    if let error = store.verifyError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.top, 6)
                    }
                    if signIn.state != .idle {
                        PendingSignInView()
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                    }
                    content(now: context.date)
                }
            }
            .padding(.vertical, 6)
            Divider()
            footer
        }
        .frame(width: 340)
        .onAppear {
            controller.panelOpened()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: MenuBarIcon.mark)
                .foregroundStyle(.secondary)
            Text("Varlatch")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if store.cliState == .ready, !store.servers.isEmpty {
                Button {
                    controller.verify()
                } label: {
                    if store.verifying {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Verifying")
                        }
                    } else {
                        Text("Verify")
                    }
                }
                .disabled(store.verifying)
                .help("Check each stored credential with its server")
                Button("Dashboard") { controller.openDashboard() }
                    .help("Open \(store.knownServer.map(Sessions.host(of:)) ?? "the server") in your browser")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch store.cliState {
        case .unknown:
            MessageView(symbol: "hourglass", title: "Reading sessions…")
        case .missing(let searched):
            MessageView(symbol: "terminal", title: "The varlatch CLI was not found",
                        detail: "Looked for it in " + Self.list(searched.map(Self.abbreviated)) + ".")
        case .pathUnusable(let path):
            MessageView(symbol: "terminal", title: "The CLI set in Settings cannot run",
                        detail: Self.abbreviated(path), isError: true)
        case .unsupported:
            MessageView(symbol: "exclamationmark.triangle", title: "This varlatch CLI is too old",
                        detail: "It has no status command. Update the CLI to use it here.", isError: true)
        case .unavailable(let detail):
            MessageView(symbol: "exclamationmark.triangle", title: "The varlatch CLI did not answer",
                        detail: detail, isError: true)
        case .ready:
            if store.servers.isEmpty {
                signedOut
            } else {
                VStack(spacing: 0) {
                    ForEach(store.servers) { server in
                        SessionRow(server: server, probe: store.probe(for: server), now: now)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var signedOut: some View {
        if let known = store.knownServer {
            MessageView(symbol: "person.crop.circle.badge.questionmark",
                        title: "Not logged in to \(Sessions.host(of: known))") {
                if signIn.state == .idle {
                    Button("Log In") { controller.signIn(to: known) }
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                }
            }
        } else {
            MessageView(symbol: "person.crop.circle.badge.questionmark", title: "Not logged in",
                        detail: "Sign in with: varlatch login --server <address>")
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(verbatim: store.cliVersion.map { "CLI \($0.description)" } ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            SettingsOpener.Button {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Varlatch")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// "a, b, and c".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }
}

/// A sign-in waiting in the browser, with its link (for when the page
/// opened in the wrong browser, or not at all) and a way to stop it.
@MainActor
struct PendingSignInView: View {
    @EnvironmentObject private var signIn: SignInController
    @EnvironmentObject private var controller: AppController

    var body: some View {
        if case .browser(let server, let link) = signIn.state {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Signing in to \(Sessions.host(of: server))")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("Finish in your browser.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Open Link") { link.map(controller.open) }
                        .disabled(link == nil)
                        .help("Open the sign-in page again, for when it opened in the wrong browser")
                    Button("Cancel") { controller.cancelSignIn() }
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        }
    }
}

/// One stored credential: its server, how long it has left, and what can
/// be done with it.
@MainActor
struct SessionRow: View {
    let server: ServerStatus
    let probe: ServerStatus.Probe?
    let now: Date
    @EnvironmentObject private var signIn: SignInController
    @EnvironmentObject private var controller: AppController

    var body: some View {
        let health = server.health(now: now)
        HStack(spacing: 10) {
            Circle()
                .fill(color(for: health))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(Sessions.host(of: server.server))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail(health)
                    .font(.system(size: 11))
            }
            Spacer(minLength: 8)
            if controller.loggingOut.contains(server.server) {
                ProgressView().controlSize(.small)
            } else {
                if signIn.state == .idle {
                    // Renewing is signing in again: the CLI revokes the old
                    // credential only once the new one is saved.
                    if health == .expired {
                        Button("Log In") { controller.signIn(to: server.server) }
                    } else {
                        Button("Renew") { controller.signIn(to: server.server) }
                            .help("Sign in again for a fresh session")
                    }
                }
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Open Dashboard") { controller.openDashboard(server.server) }
        Button("Copy Address") { controller.copy(server.server) }
        Divider()
        Button("Log Out") { controller.logout(server.server) }
    }

    private func detail(_ health: SessionHealth) -> Text {
        let base = Text(Sessions.detail(for: server, now: now))
            .foregroundColor(health == .ok ? .secondary : color(for: health))
        guard let probe else { return base }
        return base
            + Text(" · ").foregroundColor(.secondary)
            + Text(Sessions.probeText(probe)).foregroundColor(probe.state == .valid ? .secondary : .red)
    }

    private func color(for health: SessionHealth) -> Color {
        switch health {
        case .ok: return .green
        case .expiring: return .orange
        case .expired: return .red
        }
    }
}

/// A short explanation in place of the sessions, with room for buttons.
@MainActor
struct MessageView<Actions: View>: View {
    let symbol: String
    let title: String
    var detail: String?
    var isError = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                actions()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

extension MessageView where Actions == EmptyView {
    init(symbol: String, title: String, detail: String? = nil, isError: Bool = false) {
        self.init(symbol: symbol, title: title, detail: detail, isError: isError) { EmptyView() }
    }
}
