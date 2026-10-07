import Foundation
import Testing
@testable import VarlatchKit

@MainActor
struct SignInTests {
    let fake = FakeCLI()

    func controller() -> (SignInController, Outcomes) {
        let outcomes = Outcomes()
        let fake = self.fake
        let controller = SignInController { (FakeCLI.path, fake.environment) }
        controller.onOutcome = { outcomes.list.append($0) }
        controller.onFinished = { outcomes.finished += 1 }
        return (controller, outcomes)
    }

    final class Outcomes { var list: [SignInController.Outcome] = []; var finished = 0 }

    func waitForLink(_ controller: SignInController) async -> String? {
        for _ in 0..<100 {
            if case .browser(_, let link?) = controller.state { return link }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    @Test func signsIn() async {
        fake.set(["FAKE_LOGIN_SLEEP": "1"])
        let (controller, outcomes) = controller()
        controller.signIn(server: "https://vl.example.com", ttlArguments: ["--ttl", "28800"])
        #expect(controller.state == .browser(server: "https://vl.example.com", link: nil) || !controller.isIdle)
        let link = await waitForLink(controller)
        #expect(link == "https://vl.example.com/enroll?callback=http%3A%2F%2F127.0.0.1%3A49152%2F")
        await controller.waitUntilIdle()
        #expect(controller.isIdle)
        #expect(outcomes.list == [.signedIn(server: "https://vl.example.com", warning: nil)])
        #expect(outcomes.list[0].message == "Logged in to vl.example.com.")
        #expect(outcomes.finished == 1)
        #expect(fake.calls == ["cli login --server https://vl.example.com --ttl 28800"])
    }

    @Test func oneAtATimeAndASecondClickGivesTheLink() async {
        fake.set(["FAKE_LOGIN_SLEEP": "2"])
        let (controller, _) = controller()
        #expect(controller.signIn(server: "https://vl.example.com") == nil)
        _ = await waitForLink(controller)
        #expect(controller.signIn(server: "https://other.example.com")?.hasSuffix("/enroll?callback=http%3A%2F%2F127.0.0.1%3A49152%2F") == true)
        await controller.waitUntilIdle()
        #expect(fake.calls.count == 1)
    }

    @Test func reportsAFailedRevoke() async {
        fake.set(["FAKE_REVOKE_FAIL": "1"])
        let (controller, outcomes) = controller()
        controller.signIn(server: "https://vl.example.com")
        await controller.waitUntilIdle()
        #expect(outcomes.list == [.signedIn(server: "https://vl.example.com",
                                            warning: "varlatch: previous credential not revoked (network error); it may remain live.")])
    }

    @Test func fails() async {
        fake.set(["FAKE_LOGIN_RC": "1"])
        let (controller, outcomes) = controller()
        controller.signIn(server: "https://vl.example.com")
        await controller.waitUntilIdle()
        #expect(outcomes.list == [.failed(server: "https://vl.example.com", message: "varlatch login: browser sign-in failed: no passkey")])
        #expect(outcomes.list[0].message == "Sign-in to vl.example.com failed: varlatch login: browser sign-in failed: no passkey")
        #expect(outcomes.finished == 1)
    }

    @Test func cancels() async {
        fake.set(["FAKE_LOGIN_SLEEP": "30"])
        let (controller, outcomes) = controller()
        controller.signIn(server: "https://vl.example.com")
        _ = await waitForLink(controller)
        controller.cancel()
        await controller.waitUntilIdle()
        #expect(outcomes.list == [.cancelled(server: "https://vl.example.com")])
        #expect(outcomes.list[0].message == "Sign-in to vl.example.com cancelled.")
    }

    @Test func cancelsQuietly() async {
        fake.set(["FAKE_LOGIN_SLEEP": "30"])
        let (controller, outcomes) = controller()
        controller.signIn(server: "https://vl.example.com")
        _ = await waitForLink(controller)
        controller.cancel(quietly: true)
        await controller.waitUntilIdle()
        #expect(outcomes.list.isEmpty)
        #expect(outcomes.finished == 1)
    }

    @Test func noCLI() {
        let outcomes = Outcomes()
        let controller = SignInController { nil }
        controller.onOutcome = { outcomes.list.append($0) }
        controller.signIn(server: "https://vl.example.com")
        #expect(controller.isIdle)
        #expect(outcomes.list == [.failed(server: "https://vl.example.com", message: "the varlatch CLI was not found.")])
    }

    @Test func enrollLink() {
        #expect(SignInController.enrollLink(in: "Complete passkey sign-in in your browser:\n  https://a.example.com/enroll?callback=x\n")
                == "https://a.example.com/enroll?callback=x")
        #expect(SignInController.enrollLink(in: "Complete passkey sign-in in your browser:\n") == nil)
    }
}

@MainActor
struct StoreActionTests {
    let fake = FakeCLI()

    func store() -> SessionStore {
        SessionStore(preferences: Preferences(cliPath: FakeCLI.path), baseEnvironment: fake.environment,
                     home: fake.dir.path, stateDirectory: fake.dir.appendingPathComponent("state"))
    }

    @Test func verifyPutsResultsOnTheRows() async {
        fake.setStatus(FakeCLI.status(FakeCLI.server("https://a.example.com"), FakeCLI.server("https://b.example.com")))
        fake.setProbe(#"{"version":1,"servers":[{"server":"https://a.example.com","credentialId":"crd_x","probe":{"state":"valid","detail":null}},{"server":"https://b.example.com","credentialId":"crd_x","probe":{"state":"invalid","detail":"401 UNAUTHENTICATED"}}]}"#)
        let store = store()
        await store.refresh()
        await store.verify()
        #expect(store.verifyError == nil)
        #expect(store.servers.map { store.probe(for: $0)?.state } == [.valid, .invalid])
        #expect(Sessions.probeText(store.probe(for: store.servers[1])!) == "invalid (401 UNAUTHENTICATED)")
        // They stay through the next read of the same credentials.
        await store.refresh()
        #expect(store.probe(for: store.servers[0])?.state == .valid)
        #expect(fake.calls.contains("cli status --probe --json"))
    }

    @Test func aNewCredentialDropsTheProbe() async {
        fake.setStatus(FakeCLI.status(FakeCLI.server("https://a.example.com")))
        fake.setProbe(#"{"version":1,"servers":[{"server":"https://a.example.com","credentialId":"crd_x","probe":{"state":"valid","detail":null}}]}"#)
        let store = store()
        await store.verify()
        #expect(store.probe(for: store.servers[0]) != nil)
        fake.setStatus(FakeCLI.status(FakeCLI.server("https://a.example.com").replacingOccurrences(of: "crd_x", with: "crd_new")))
        await store.refresh()
        #expect(store.probe(for: store.servers[0]) == nil)
    }

    @Test func verifyFailure() async {
        fake.setProbe("not json")
        let store = store()
        await store.verify()
        #expect(store.verifyError == "Verify failed: unreadable output from the CLI.")
        #expect(!store.verifying)
    }

    @Test func logout() async {
        fake.setStatus(FakeCLI.status(FakeCLI.server("https://a.example.com")))
        let store = store()
        let result = await store.logout(server: "https://a.example.com")
        #expect(result.succeeded)
        #expect(result.message == "Logged out of a.example.com.")
        #expect(fake.calls.contains("cli logout --server https://a.example.com"))
        fake.set(["FAKE_LOGOUT_FAIL": "1"])
        let failed = await store.logout(server: "https://a.example.com")
        #expect(!failed.succeeded)
        #expect(failed.message == "Log out of a.example.com failed: varlatch: No stored credential for https://a.example.com")
    }

    @Test func remembersServersAcrossLogout() async {
        fake.setStatus(FakeCLI.status(FakeCLI.server("http://localhost:3000"), FakeCLI.server("https://vl.example.com")))
        let store = store()
        await store.refresh()
        #expect(store.knownServer == "https://vl.example.com")
        fake.setStatus(FakeCLI.status())
        await store.refresh()
        #expect(store.servers.isEmpty)
        #expect(store.knownServer == "https://vl.example.com")
        // Kept on disk for the next start.
        let again = self.store()
        #expect(again.knownServer == "https://vl.example.com")
        #expect(again.memory.servers == ["http://localhost:3000", "https://vl.example.com"])
    }
}

struct ServerMemoryTests {
    @Test func newestFirstWithoutRepeats() {
        var memory = ServerMemory(servers: ["https://a", "https://b"])
        memory.remember(["https://c", "https://a"])
        #expect(memory.servers == ["https://c", "https://a", "https://b"])
        memory.forget("https://a")
        #expect(memory.servers == ["https://c", "https://b"])
    }

    @Test func limited() {
        var memory = ServerMemory()
        memory.remember((0..<15).map { "https://s\($0)" })
        #expect(memory.servers.count == ServerMemory.limit)
    }

    @Test func realDeploymentsFirst() {
        let memory = ServerMemory(servers: ["http://localhost:3000", "https://vl.example.com"])
        #expect(memory.preferred(showLocalhost: false) == "https://vl.example.com")
        #expect(memory.preferred(showLocalhost: true) == "https://vl.example.com")
        #expect(ServerMemory(servers: ["http://localhost:3000"]).preferred(showLocalhost: false) == nil)
        #expect(ServerMemory(servers: ["http://localhost:3000"]).preferred(showLocalhost: true) == "http://localhost:3000")
    }
}
