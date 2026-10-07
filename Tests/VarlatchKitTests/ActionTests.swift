import CoreGraphics
import CoreImage
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
        #expect(outcomes.list == [.failed(server: "https://vl.example.com", message: "varlatch login: browser sign-in failed: no passkey", browser: true)])
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
        #expect(outcomes.list == [.failed(server: "https://vl.example.com", message: "the varlatch CLI was not found.", browser: false)])
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

@MainActor
struct DeviceSignInTests {
    let fake = FakeCLI()

    final class Outcomes { var list: [SignInController.Outcome] = [] }

    func controller() -> (SignInController, Outcomes) {
        let outcomes = Outcomes()
        let fake = self.fake
        let controller = SignInController { (FakeCLI.path, fake.environment) }
        controller.onOutcome = { outcomes.list.append($0) }
        return (controller, outcomes)
    }

    func waitForCode(_ controller: SignInController) async -> DeviceCode? {
        for _ in 0..<100 {
            if case .device(_, let code?) = controller.state { return code }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    @Test func approved() async {
        let (controller, outcomes) = controller()
        await controller.signInFromAnotherDevice(server: "https://vl.example.com", ttlArguments: ["--ttl", "3600"])
        #expect(outcomes.list == [.signedIn(server: "https://vl.example.com", warning: nil)])
        #expect(controller.isIdle)
        // --ttl goes with --start only; --wait refuses it.
        #expect(fake.calls == [
            "cli login --server https://vl.example.com --start --json --ttl 3600",
            "cli login --server https://vl.example.com --wait --timeout 600 --json",
        ])
    }

    @Test func showsTheCodeWhileWaiting() async {
        fake.set(["FAKE_WAIT": "pending-once"])
        let (controller, outcomes) = controller()
        let task = Task { await controller.signInFromAnotherDevice(server: "https://vl.example.com") }
        let code = await waitForCode(controller)
        #expect(code?.verificationUri == "https://vl.example.com/device")
        #expect(code?.userCode == "BCDF-GHJK")
        #expect(code?.expiryText().hasPrefix("Code expires in 9m") == true)
        await task.value
        // Pending once (75), asked again, then approved.
        #expect(fake.calls.filter { $0.contains("--wait") }.count == 2)
        #expect(outcomes.list == [.signedIn(server: "https://vl.example.com", warning: nil)])
    }

    @Test func denied() async {
        fake.set(["FAKE_WAIT": "deny"])
        let (controller, outcomes) = controller()
        await controller.signInFromAnotherDevice(server: "https://vl.example.com")
        #expect(outcomes.list == [.denied(server: "https://vl.example.com")])
        #expect(outcomes.list[0].message == "Sign-in to vl.example.com was denied.")
    }

    @Test func codeExpired() async {
        fake.set(["FAKE_WAIT": "expire"])
        let (controller, outcomes) = controller()
        await controller.signInFromAnotherDevice(server: "https://vl.example.com")
        #expect(outcomes.list == [.codeExpired(server: "https://vl.example.com")])
        #expect(outcomes.list[0].message == "The sign-in code for vl.example.com expired before it was approved.")
    }

    @Test func startRefused() async {
        fake.set(["FAKE_START_FAIL": "1"])
        let (controller, outcomes) = controller()
        await controller.signInFromAnotherDevice(server: "https://vl.example.com")
        #expect(outcomes.list == [.failed(server: "https://vl.example.com",
                                          message: "varlatch login: the server refused to start a sign-in (NOT_FOUND)",
                                          browser: false)])
        #expect(!fake.calls.contains { $0.contains("--wait") })
    }

    @Test func cancelWhileWaiting() async {
        fake.set(["FAKE_WAIT": "hang"])
        let (controller, outcomes) = controller()
        let task = Task { await controller.signInFromAnotherDevice(server: "https://vl.example.com") }
        _ = await waitForCode(controller)
        controller.cancel()
        await task.value
        #expect(outcomes.list == [.cancelled(server: "https://vl.example.com")])
        #expect(controller.isIdle)
    }

    @Test func takesOverABrowserSignInQuietly() async {
        fake.set(["FAKE_LOGIN_SLEEP": "30"])
        let (controller, outcomes) = controller()
        controller.signIn(server: "https://vl.example.com")
        #expect(!controller.isIdle)
        await controller.signInFromAnotherDevice(server: "https://vl.example.com")
        // No "cancelled" for the browser sign-in that made way.
        #expect(outcomes.list == [.signedIn(server: "https://vl.example.com", warning: nil)])
    }

    @Test func expiryText() {
        let now = date("2026-10-07T12:00:00Z")
        func code(_ expires: String) -> DeviceCode {
            DeviceCode(verificationUri: "https://a/device", userCode: "X", expiresAt: date(expires))
        }
        #expect(code("2026-10-07T12:09:59Z").expiryText(now: now) == "Code expires in 9m")
        #expect(code("2026-10-07T12:00:30Z").expiryText(now: now) == "Code expires in under a minute")
        #expect(code("2026-10-07T11:59:00Z").expiryText(now: now) == "Code expired")
        #expect(DeviceCode.parse(#"{"verificationUri":"https://a/device","userCode":"BCDF-GHJK","expiresAt":"2026-10-07T12:10:00.000Z"}"#)?.userCode == "BCDF-GHJK")
        #expect(DeviceCode.parse(#"{"state":"pending"}"#) == nil)
    }

    @Test func waitStates() {
        #expect(SignInController.waitState(#"{"state":"denied"}"#) == "denied")
        #expect(SignInController.waitState("noise\n{\"state\":\"expired\"}\n") == "expired")
        #expect(SignInController.waitState("") == nil)
    }
}

struct QRCodeTests {
    @Test func readsBackTheAddress() throws {
        let image = try #require(QRCode.image(for: "https://vl.example.com/device"))
        // Scaled up, with a white quiet zone, as the panel shows it.
        let scale = 8, margin = 4
        let side = (image.width + 2 * margin) * scale
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: margin * scale, y: margin * scale, width: image.width * scale, height: image.height * scale))
        let framed = try #require(context.makeImage())
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil))
        let found = detector.features(in: CIImage(cgImage: framed)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(found == ["https://vl.example.com/device"])
    }
}
