import SwiftUI
import VarlatchKit

/// The panel under the menu bar icon: one row per session with a live
/// countdown, or what stands in the way.
struct PanelView: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // Countdowns move on their own between reads.
            TimelineView(.periodic(from: .now, by: 10)) { context in
                content(now: context.date)
            }
            .padding(.vertical, 6)
            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear {
            AppController.shared.panelOpened()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: MenuBarIcon.mark)
                .foregroundStyle(.secondary)
            Text("Varlatch")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
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
                MessageView(symbol: "person.crop.circle.badge.questionmark", title: "Not logged in",
                            detail: "Sign in with: varlatch login --server <address>")
            } else {
                VStack(spacing: 0) {
                    ForEach(store.servers) { server in
                        SessionRow(server: server, now: now)
                    }
                }
            }
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

/// One stored credential: its server, and how long it has left.
struct SessionRow: View {
    let server: ServerStatus
    let now: Date

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
                Text(Sessions.detail(for: server, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(health == .ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(color(for: health)))
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func color(for health: SessionHealth) -> Color {
        switch health {
        case .ok: return .green
        case .expiring: return .orange
        case .expired: return .red
        }
    }
}

/// A short explanation in place of the sessions.
struct MessageView: View {
    let symbol: String
    let title: String
    var detail: String?
    var isError = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20)
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
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
