import Combine
import Foundation

/// The CLI to run and the environment to run it with.
public typealias CLIInvocation = (path: String, environment: [String: String])

/// What `varlatch login --start --json` hands out: an address to open on
/// any device and a code to type there. The address has no code in it on
/// purpose.
public struct DeviceCode: Equatable, Sendable, Decodable {
    public var verificationUri: String
    public var userCode: String
    public var expiresAt: Date?

    public init(verificationUri: String, userCode: String, expiresAt: Date?) {
        self.verificationUri = verificationUri
        self.userCode = userCode
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verificationUri = try c.decode(String.self, forKey: .verificationUri)
        userCode = try c.decode(String.self, forKey: .userCode)
        expiresAt = ServerStatus.date(try? c.decodeIfPresent(String.self, forKey: .expiresAt))
    }

    enum CodingKeys: String, CodingKey { case verificationUri, userCode, expiresAt }

    public static func parse(_ text: String) -> DeviceCode? {
        guard let code = try? JSONDecoder().decode(DeviceCode.self, from: Data(text.utf8)),
              !code.verificationUri.isEmpty, !code.userCode.isEmpty else { return nil }
        return code
    }

    /// "Code expires in 9m".
    public func expiryText(now: Date = Date()) -> String {
        guard let expiresAt else { return "" }
        let seconds = expiresAt.timeIntervalSince(now)
        if seconds <= 0 { return "Code expired" }
        let minutes = Int(seconds) / 60
        return minutes >= 1 ? "Code expires in \(minutes)m" : "Code expires in under a minute"
    }
}

/// Sign-ins the app starts and owns, one at a time.
///
/// A browser sign-in runs `varlatch login --server <url>`, which opens the
/// browser for the passkey prompt and waits for its callback. A device
/// sign-in (CLI 0.14.0 and newer), for when the browser here has no passkey
/// for the server, runs `login --start --json` for an address and a code,
/// then `login --wait --json` until someone approves the code on any device.
///
/// Either way the CLI revokes the credential it replaces only after the new
/// one is saved, so renewing is signing in again, and a cancelled sign-in
/// never signs anyone out.
@MainActor
public final class SignInController: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        /// Waiting for the browser. `link` is the address the CLI printed,
        /// for when the page opened in the wrong browser.
        case browser(server: String, link: String?)
        /// Waiting for approval from another device; no code yet while
        /// `--start` runs.
        case device(server: String, code: DeviceCode?)

        public var server: String? {
            switch self {
            case .idle: return nil
            case .browser(let s, _), .device(let s, _): return s
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// `warning`: the CLI's own line when the old credential could not
        /// be revoked.
        case signedIn(server: String, warning: String?)
        case cancelled(server: String)
        /// The code was denied in the browser.
        case denied(server: String)
        /// The code was not approved within its 10 minutes.
        case codeExpired(server: String)
        /// `browser`: a browser sign-in, which another device could replace.
        case failed(server: String, message: String, browser: Bool)

        public var server: String {
            switch self {
            case .signedIn(let s, _), .cancelled(let s), .denied(let s), .codeExpired(let s), .failed(let s, _, _):
                return s
            }
        }

        public var message: String {
            let host = Sessions.host(of: server)
            switch self {
            case .signedIn(_, let warning): return "Logged in to \(host)." + (warning.map { " " + $0 } ?? "")
            case .cancelled: return "Sign-in to \(host) cancelled."
            case .denied: return "Sign-in to \(host) was denied."
            case .codeExpired: return "The sign-in code for \(host) expired before it was approved."
            case .failed(_, let message, _): return "Sign-in to \(host) failed: \(message)"
            }
        }
    }

    /// Exit statuses of `login --wait`.
    static let pendingExit: Int32 = 75
    public static let waitSeconds = 600
    let startTimeout: TimeInterval = 45

    @Published public private(set) var state: State = .idle
    /// Every sign-in's end, except one cancelled to make way for another.
    public var onOutcome: ((Outcome) -> Void)?
    /// After any sign-in ends, to read the sessions again.
    public var onFinished: (() -> Void)?

    private let cli: @MainActor () -> CLIInvocation?
    private var process: CLIProcess?
    private var running = false
    private var cancelled = false
    private var quiet = false

    public init(cli: @escaping @MainActor () -> CLIInvocation?) {
        self.cli = cli
    }

    public var isIdle: Bool { state == .idle }

    // MARK: Browser

    /// Starts a browser sign-in. While one already waits, starts nothing and
    /// returns its link, for the caller to open again.
    @discardableResult
    public func signIn(server: String, ttlArguments: [String] = []) -> String? {
        if case .browser(_, let link) = state { return link }
        guard state == .idle else { return nil }
        guard let cli = cli() else {
            onOutcome?(.failed(server: server, message: "the varlatch CLI was not found.", browser: false))
            return nil
        }
        begin(.browser(server: server, link: nil))
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
            let outcome: Outcome
            if result.succeeded {
                outcome = .signedIn(server: server, warning: Self.warning(in: result))
            } else if result.signaled, !result.timedOut {
                outcome = .cancelled(server: server)
            } else {
                outcome = .failed(server: server, message: result.lastErrorLines(), browser: true)
            }
            self.finish(outcome)
        }
        return nil
    }

    private func found(link: String, server: String) {
        if case .browser(let s, nil) = state, s == server { state = .browser(server: server, link: link) }
    }

    // MARK: Another device

    /// Starts a device sign-in. A browser sign-in still waiting makes way
    /// for it quietly; a device sign-in already under way is left alone.
    public func signInFromAnotherDevice(server: String, ttlArguments: [String] = []) async {
        if case .device = state { return }
        if case .browser = state {
            cancel(quietly: true)
            await waitUntilIdle()
        }
        guard state == .idle else { return }
        guard let cli = cli() else {
            onOutcome?(.failed(server: server, message: "the varlatch CLI was not found.", browser: false))
            return
        }
        begin(.device(server: server, code: nil))

        let start = CLIProcess(executable: cli.path,
                               arguments: ["login", "--server", server, "--start", "--json"] + ttlArguments,
                               environment: cli.environment)
        process = start
        start.start(timeout: startTimeout)
        let started = await start.wait()
        if cancelled { return finish(.cancelled(server: server)) }
        guard started.succeeded else {
            return finish(.failed(server: server, message: started.lastErrorLines(), browser: false))
        }
        guard let code = DeviceCode.parse(started.stdout) else {
            return finish(.failed(server: server, message: "the CLI gave no address and code.", browser: false))
        }
        state = .device(server: server, code: code)

        // `--wait` gives up at its timeout with 75 while the code still
        // waits; ask again until it is approved, denied, or expired.
        while true {
            let wait = CLIProcess(executable: cli.path,
                                  arguments: ["login", "--server", server, "--wait",
                                              "--timeout", String(Self.waitSeconds), "--json"],
                                  environment: cli.environment)
            process = wait
            wait.start()
            let result = await wait.wait()
            if cancelled || (result.signaled && !result.timedOut) { return finish(.cancelled(server: server)) }
            if result.exitCode == Self.pendingExit, result.launchError == nil { continue }
            if result.succeeded { return finish(.signedIn(server: server, warning: Self.warning(in: result))) }
            switch Self.waitState(result.stdout) {
            case "denied": return finish(.denied(server: server))
            case "expired": return finish(.codeExpired(server: server))
            default: return finish(.failed(server: server, message: result.lastErrorLines(), browser: false))
            }
        }
    }

    /// The `state` in the last JSON line `--wait` printed.
    static func waitState(_ stdout: String) -> String? {
        guard let line = stdout.split(whereSeparator: \.isNewline).last,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        return object["state"] as? String
    }

    // MARK: Both

    /// Stops the sign-in under way. `quietly`: another sign-in takes over,
    /// so no "cancelled" outcome.
    public func cancel(quietly: Bool = false) {
        guard running else { return }
        cancelled = true
        quiet = quietly
        process?.terminate()
    }

    /// Waits for the sign-in under way to be gone.
    public func waitUntilIdle() async {
        while running {
            if let process { _ = await process.wait() }
            await Task.yield()
        }
    }

    private func begin(_ new: State) {
        state = new
        running = true
        cancelled = false
        quiet = false
    }

    private func finish(_ outcome: Outcome) {
        process = nil
        running = false
        state = .idle
        if !(quiet && outcome == .cancelled(server: outcome.server)) {
            onOutcome?(outcome)
        }
        onFinished?()
    }

    /// The CLI's `varlatch:` lines, such as a credential it could not revoke.
    static func warning(in result: CLIResult) -> String? {
        let lines = (result.stdout + "\n" + result.stderr).split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("varlatch:") }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// The fallback address in the CLI's output: `https://…/enroll?…`.
    public nonisolated static func enrollLink(in output: String) -> String? {
        guard let range = output.range(of: #"https?://[^\s]+/enroll\?[^\s]+"#, options: .regularExpression) else {
            return nil
        }
        return String(output[range])
    }
}
