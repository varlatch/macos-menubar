import Foundation
import Testing
@testable import VarlatchKit

@MainActor
struct SessionStoreTests {
    let fake = FakeCLI()

    func store(cliPath: String = FakeCLI.path, showLocalhost: Bool = false) -> SessionStore {
        SessionStore(preferences: Preferences(cliPath: cliPath, showLocalhost: showLocalhost),
                     baseEnvironment: fake.environment, home: fake.dir.path)
    }

    @Test func readsSessions() async {
        fake.setStatus(FakeCLI.status(FakeCLI.server("https://vl.example.com")))
        let store = store()
        await store.refreshVersion()
        await store.refresh()
        #expect(store.cliState == .ready)
        #expect(store.cliVersion == Version(0, 15, 1))
        #expect(store.servers.map(\.server) == ["https://vl.example.com"])
        #expect(store.overall() == .ok)
        #expect(fake.calls == ["cli --version", "cli status --json"])
    }

    @Test func signedOut() async {
        let store = store()
        await store.refresh()
        #expect(store.cliState == .ready)
        #expect(store.overall() == .signedOut)
    }

    @Test func localhostOnlyWhenAskedFor() async {
        fake.setStatus(FakeCLI.status(FakeCLI.server("http://localhost:3000"), FakeCLI.server("https://vl.example.com")))
        let store = store()
        await store.refresh()
        #expect(store.servers.map(\.server) == ["https://vl.example.com"])
        store.update(preferences: Preferences(cliPath: FakeCLI.path, showLocalhost: true))
        #expect(store.servers.count == 2)
        #expect(store.allServers.count == 2)
    }

    @Test func localhostAloneCountsAsSignedOut() async {
        fake.setStatus(FakeCLI.status(FakeCLI.server("http://127.0.0.1:8080", expired: true)))
        let store = store()
        await store.refresh()
        #expect(store.overall() == .signedOut)
    }

    @Test func expiryEventsOncePerTransition() async {
        fake.setStatus(FakeCLI.status(FakeCLI.server("https://vl.example.com", expiresIn: 1, expiring: true)))
        let store = store()
        var events: [ExpiryEvent] = []
        store.onExpiryEvents = { events += $0 }
        await store.refresh()
        await store.refresh()
        #expect(events.map(\.health) == [.expiring])
        #expect(store.overall() == .expiring)
        fake.setStatus(FakeCLI.status(FakeCLI.server("https://vl.example.com", expiresIn: -1, expired: true)))
        await store.refresh()
        #expect(events.map(\.health) == [.expiring, .expired])
        #expect(store.overall() == .expired)
    }

    @Test func cliMissing() async {
        let store = SessionStore(preferences: Preferences(), baseEnvironment: fake.environment,
                                 home: fake.dir.path, isExecutable: { _ in false })
        await store.refresh()
        #expect(store.cliState == .missing(searched: [
            "/opt/homebrew/bin/varlatch", "/usr/local/bin/varlatch", fake.dir.path + "/.local/bin/varlatch",
        ]))
        #expect(store.overall() == .cliMissing)
    }

    @Test func setPathThatCannotRun() async {
        let store = store(cliPath: "/nonexistent/varlatch")
        await store.refresh()
        #expect(store.cliState == .pathUnusable("/nonexistent/varlatch"))
        #expect(store.overall() == .cliMissing)
    }

    @Test func tooOldForStatus() async {
        fake.set(["FAKE_NO_STATUS": "1"])
        let store = store()
        await store.refresh()
        #expect(store.cliState == .unsupported)
        #expect(store.overall() == .unsupported)
    }

    @Test func nodeMissing() async throws {
        // The release CLI starts with `#!/usr/bin/env node`.
        let script = fake.dir.appendingPathComponent("varlatch-release")
        try "#!/usr/bin/env node-that-does-not-exist\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let store = store(cliPath: script.path)
        await store.refresh()
        #expect(store.cliState == .unavailable("Node.js was not found. The varlatch CLI needs Node.js 22 or newer."))
    }

    @Test func unreadableOutput() async {
        fake.setStatus("not json")
        let store = store()
        await store.refresh()
        #expect(store.cliState == .unavailable("unreadable status output"))
    }

    @Test func neverTwoReadsAtOnce() async {
        fake.setStatus(FakeCLI.status())
        let store = store()
        async let a: Void = store.refresh()
        async let b: Void = store.refresh()
        async let c: Void = store.refresh()
        _ = await (a, b, c)
        // One read, plus one more for the requests made while it ran.
        #expect(fake.calls.filter { $0 == "cli status --json" }.count == 2)
    }
}

struct CLIProcessTests {
    let fake = FakeCLI()

    @Test func separateOutputs() async {
        let result = await CLIProcess.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"],
                                          environment: fake.environment, timeout: 10)
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
        #expect(result.exitCode == 3)
        #expect(!result.succeeded)
    }

    @Test func timeout() async {
        let start = Date()
        let result = await CLIProcess.run("/bin/sleep", ["30"], environment: fake.environment, timeout: 0.5)
        #expect(result.timedOut)
        #expect(result.signaled)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(result.lastErrorLines() == "the CLI did not finish in time")
    }

    @Test func terminate() async {
        let process = CLIProcess(executable: "/bin/sleep", arguments: ["30"], environment: fake.environment)
        process.start()
        #expect(process.isRunning)
        process.terminate()
        let result = await process.wait()
        #expect(result.signaled)
        #expect(!process.isRunning)
    }

    @Test func cannotStart() async {
        let result = await CLIProcess.run("/nonexistent", [], environment: fake.environment, timeout: 5)
        #expect(result.launchError != nil)
        #expect(!result.succeeded)
    }

    @Test func lastErrorLines() {
        let r = CLIResult(exitCode: 1, stderr: "varlatch login: one\n  indented detail\nvarlatch login: two\nthree\n")
        #expect(r.lastErrorLines() == "varlatch login: two three")
        #expect(CLIResult(exitCode: 1, stdout: "only stdout\n").lastErrorLines() == "only stdout")
    }

    @Test func streamsStdout() async {
        final class Box: @unchecked Sendable { var seen: [String] = []; let lock = NSLock() }
        let box = Box()
        let process = CLIProcess(executable: "/bin/sh", arguments: ["-c", "echo first; sleep 0.3; echo second"],
                                 environment: fake.environment) { text in
            box.lock.lock(); box.seen.append(text); box.lock.unlock()
        }
        process.start()
        _ = await process.wait()
        #expect(box.seen.first == "first\n")
        #expect(box.seen.last == "first\nsecond\n")
    }
}
