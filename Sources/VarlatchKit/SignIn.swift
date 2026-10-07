import Combine
import Foundation

/// The CLI to run and the environment to run it with.
public typealias CLIInvocation = (path: String, environment: [String: String])

/// Sign-ins the app starts and owns, one at a time. A browser sign-in runs
/// `varlatch login --server <url>`, which opens the browser for the passkey
/// prompt and waits for its callback. The CLI revokes the credential it
/// replaces only after the new one is saved, so renewing is signing in
/// again, and a cancelled sign-in never signs anyone out.
@MainActor
public final class SignInController: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        /// Waiting for the browser. `link` is the address the CLI printed,
        /// for when the page opened in the wrong browser.
        case browser(server: String, link: String?)
    }

    public enum Outcome: Equatable, Sendable {
        /// `warning`: the CLI's own line when the old credential could not
        /// be revoked.
        case signedIn(server: String, warning: String?)
        case cancelled(server: String)
        case failed(server: String, message: String)

        public var server: String {
            switch self {
            case .signedIn(let s, _), .cancelled(let s), .failed(let s, _): return s
            }
        }

        public var message: String {
            let host = Sessions.host(of: server)
            switch self {
            case .signedIn(_, let warning): return "Logged in to \(host)." + (warning.map { " " + $0 } ?? "")
            case .cancelled: return "Sign-in to \(host) cancelled."
            case .failed(_, let message): return "Sign-in to \(host) failed: \(message)"
            }
        }
    }

    @Published public private(set) var state: State = .idle
    /// Every sign-in's end, except one cancelled to make way for another.
    public var onOutcome: ((Outcome) -> Void)?
    /// After any sign-in ends, to read the sessions again.
    public var onFinished: (() -> Void)?

    private let cli: @MainActor () -> CLIInvocation?
    private var process: CLIProcess?
    private var quiet = false

    public init(cli: @escaping @MainActor () -> CLIInvocation?) {
        self.cli = cli
    }

    public var isIdle: Bool { state == .idle }

    /// Starts a browser sign-in. While one already waits, starts nothing and
    /// returns its link, for the caller to open again.
    @discardableResult
    public func signIn(server: String, ttlArguments: [String] = []) -> String? {
        if case .browser(_, let link) = state { return link }
        guard state == .idle else { return nil }
        guard let cli = cli() else {
            onOutcome?(.failed(server: server, message: "the varlatch CLI was not found."))
            return nil
        }
        state = .browser(server: server, link: nil)
        quiet = false
        let process = CLIProcess(executable: cli.path, arguments: ["login", "--server", server] + ttlArguments,
                                 environment: cli.environment) { [weak self] stdout in
            guard let link = Self.enrollLink(in: stdout) else { return }
            let controller = self
            Task { @MainActor in controller?.found(link: link, server: server) }
        }
        self.process = process
        process.start()
        Task {
            let result = await process.wait()
            self.finished(result, server: server)
        }
        return nil
    }

    /// Stops the waiting sign-in. `quietly`: another sign-in takes over, so
    /// no "cancelled" outcome.
    public func cancel(quietly: Bool = false) {
        guard let process else { return }
        quiet = quietly
        process.terminate()
    }

    /// Waits for a cancelled sign-in to be gone.
    public func waitUntilIdle() async {
        while let process { _ = await process.wait(); await Task.yield() }
    }

    private func found(link: String, server: String) {
        if case .browser(let s, nil) = state, s == server { state = .browser(server: server, link: link) }
    }

    private func finished(_ result: CLIResult, server: String) {
        process = nil
        state = .idle
        if result.succeeded {
            let warning = (result.stdout + "\n" + result.stderr).split(whereSeparator: \.isNewline)
                .filter { $0.hasPrefix("varlatch:") }.joined(separator: " ")
            onOutcome?(.signedIn(server: server, warning: warning.isEmpty ? nil : warning))
        } else if result.signaled, !result.timedOut {
            if !quiet { onOutcome?(.cancelled(server: server)) }
        } else {
            onOutcome?(.failed(server: server, message: result.lastErrorLines()))
        }
        onFinished?()
    }

    /// The fallback address in the CLI's output: `https://…/enroll?…`.
    public nonisolated static func enrollLink(in output: String) -> String? {
        guard let range = output.range(of: #"https?://[^\s]+/enroll\?[^\s]+"#, options: .regularExpression) else {
            return nil
        }
        return String(output[range])
    }
}
