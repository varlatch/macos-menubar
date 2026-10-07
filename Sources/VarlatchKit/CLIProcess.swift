import Foundation

/// How a CLI command ended.
public struct CLIResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    /// Ended by a signal: a cancel, the app quitting, or the timeout.
    public var signaled: Bool
    /// Stopped because it ran past its timeout.
    public var timedOut: Bool
    /// The process could not start at all.
    public var launchError: String?

    public init(exitCode: Int32, stdout: String = "", stderr: String = "", signaled: Bool = false,
                timedOut: Bool = false, launchError: String? = nil) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.signaled = signaled
        self.timedOut = timedOut
        self.launchError = launchError
    }

    public var succeeded: Bool { exitCode == 0 && !signaled && launchError == nil }

    /// The last lines of stderr (or stdout when stderr is empty) that are not
    /// indented, for a short error message, as the plugin shows them.
    public func lastErrorLines(_ count: Int = 2) -> String {
        if let launchError { return launchError }
        if timedOut { return "the CLI did not finish in time" }
        let source = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr
        let lines = source.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasPrefix(" ") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.suffix(count).joined(separator: " ")
    }
}

/// One run of the CLI: separate stdout and stderr, stdin closed, an optional
/// timeout, and a way to stop it. Never blocks the caller; `wait()` suspends
/// until the process has exited and its output is read.
public final class CLIProcess: @unchecked Sendable {
    public let executable: String
    public let arguments: [String]

    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let lock = NSLock()
    private var outData = Data()
    private var errData = Data()
    private var outClosed = false
    private var errClosed = false
    private var exited = false
    private var timedOut = false
    private var result: CLIResult?
    private var waiters: [CheckedContinuation<CLIResult, Never>] = []
    private let onStdout: (@Sendable (String) -> Void)?

    /// `onStdout` gets everything printed to stdout so far, each time more
    /// arrives, on a background queue: for the browser sign-in's address.
    public init(executable: String, arguments: [String], environment: [String: String],
                onStdout: (@Sendable (String) -> Void)? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.onStdout = onStdout
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe
    }

    public var processIdentifier: Int32 { process.processIdentifier }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return result == nil
    }

    /// Starts the process. A process that cannot start finishes at once with
    /// `launchError` set.
    public func start(timeout: TimeInterval? = nil) {
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.received(handle.availableData, stdout: true)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.received(handle.availableData, stdout: false)
        }
        process.terminationHandler = { [weak self] _ in self?.processExited() }
        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            finish(CLIResult(exitCode: 127, launchError: "cannot run \(executable): \(error.localizedDescription)"))
            return
        }
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.isRunning else { return }
                self.lock.lock(); self.timedOut = true; self.lock.unlock()
                self.terminate()
            }
        }
    }

    /// SIGTERM, then SIGKILL two seconds later if it is still running.
    public func terminate() {
        guard isRunning, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.process.isRunning else { return }
            kill(pid, SIGKILL)
        }
    }

    /// Suspends until the process has exited.
    public func wait() async -> CLIResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func received(_ data: Data, stdout: Bool) {
        var snapshot: String?
        lock.lock()
        if data.isEmpty {
            if stdout { outClosed = true } else { errClosed = true }
            (stdout ? outPipe : errPipe).fileHandleForReading.readabilityHandler = nil
        } else if stdout {
            outData.append(data)
            if onStdout != nil { snapshot = String(decoding: outData, as: UTF8.self) }
        } else {
            errData.append(data)
        }
        let done = exited && outClosed && errClosed
        lock.unlock()
        if let snapshot { onStdout?(snapshot) }
        if done { complete() }
    }

    private func processExited() {
        lock.lock()
        exited = true
        let done = outClosed && errClosed
        lock.unlock()
        if done {
            complete()
        } else {
            // A child that outlives the CLI could keep the pipes open; do not
            // wait for it longer than a moment.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in self?.complete() }
        }
    }

    private func complete() {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        let out = String(decoding: outData, as: UTF8.self)
        let err = String(decoding: errData, as: UTF8.self)
        let signaled = process.terminationReason == .uncaughtSignal
        let r = CLIResult(exitCode: process.terminationStatus, stdout: out, stderr: err,
                          signaled: signaled, timedOut: timedOut)
        lock.unlock()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        finish(r)
    }

    private func finish(_ r: CLIResult) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = r
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume(returning: r) }
    }
}

public extension CLIProcess {
    /// Runs a command to the end.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String],
                    timeout: TimeInterval?) async -> CLIResult {
        let process = CLIProcess(executable: executable, arguments: arguments, environment: environment)
        process.start(timeout: timeout)
        return await process.wait()
    }
}
