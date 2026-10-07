import Foundation
import Testing
@testable import VarlatchKit

struct ServerAddressTests {
    @Test func addsHttpsAndTrims() {
        #expect(ServerAddress.normalize("varlatch.example.com") == "https://varlatch.example.com")
        #expect(ServerAddress.normalize("  vl.example.com/ ") == "https://vl.example.com")
        #expect(ServerAddress.normalize("https://vl.example.com//") == "https://vl.example.com")
        #expect(ServerAddress.normalize("http://localhost:3000") == "http://localhost:3000")
        #expect(ServerAddress.normalize("vl.example.com:8443/varlatch") == "https://vl.example.com:8443/varlatch")
    }

    @Test func refusesWhatCannotBeAServer() {
        #expect(ServerAddress.normalize("") == nil)
        #expect(ServerAddress.normalize("   ") == nil)
        #expect(ServerAddress.normalize("ftp://vl.example.com") == nil)
        #expect(ServerAddress.normalize("https://vl.example.com/?x=1") == nil)
        #expect(ServerAddress.normalize("https:///path") == nil)
    }
}

struct CLIInstallTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vl-install-\(UUID().uuidString)")

    func file(_ path: String, _ contents: String) -> String {
        let url = dir.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func homebrewThroughItsLink() throws {
        let target = file("Cellar/varlatch/0.15.1/bin/varlatch", "#!/bin/bash\n")
        let link = dir.appendingPathComponent("bin/varlatch")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        #expect(CLIInstall.kind(of: link.path) == .homebrew)
    }

    @Test func releaseBuild() {
        let path = file("local/bin/varlatch", "#!/usr/bin/env node\n/*! Varlatch CLI. Copyright 2026 Robotsson. */\n")
        #expect(CLIInstall.kind(of: path) == .release)
    }

    @Test func sourceCheckout() throws {
        let path = file("src/varlatch/apps/cli/dist/main.js", "#!/usr/bin/env node\n")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src/varlatch/.git"), withIntermediateDirectories: true)
        #expect(CLIInstall.kind(of: path) == .checkout)
    }

    @Test func anythingElse() {
        #expect(CLIInstall.kind(of: file("other/varlatch", "#!/bin/sh\nexec something\n")) == .custom)
    }
}

struct ReleaseRulesTests {
    let now = date("2026-10-07T12:00:00Z")
    func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    @Test func firstCheck() {
        #expect(ReleaseRules.shouldFetch(ReleaseCache(), current: Version(0, 15, 1), maxAge: ReleaseRules.backgroundMaxAge, now: now))
    }

    @Test func twelveHoursInTheBackgroundAnHourFromThePanel() {
        let cache = ReleaseCache(latest: "0.15.1", checkedAt: ago(2), attemptedAt: ago(2))
        #expect(!ReleaseRules.shouldFetch(cache, current: Version(0, 15, 1), maxAge: ReleaseRules.backgroundMaxAge, now: now))
        #expect(ReleaseRules.shouldFetch(cache, current: Version(0, 15, 1), maxAge: ReleaseRules.panelMaxAge, now: now))
        let old = ReleaseCache(latest: "0.15.1", checkedAt: ago(13), attemptedAt: ago(13))
        #expect(ReleaseRules.shouldFetch(old, current: Version(0, 15, 1), maxAge: ReleaseRules.backgroundMaxAge, now: now))
    }

    @Test func aCacheOlderThanTheInstalledCLI() {
        let cache = ReleaseCache(latest: "0.15.1", checkedAt: ago(1.5), attemptedAt: ago(1.5))
        #expect(ReleaseRules.shouldFetch(cache, current: Version(0, 16, 0), maxAge: ReleaseRules.backgroundMaxAge, now: now))
    }

    @Test func neverMoreThanOnceAnHourFailuresIncluded() {
        // The last answer is old, but a check failed 30 minutes ago.
        let failed = ReleaseCache(latest: "0.15.1", checkedAt: ago(20), attemptedAt: ago(0.5))
        #expect(!ReleaseRules.shouldFetch(failed, current: Version(0, 15, 1), maxAge: ReleaseRules.panelMaxAge, now: now))
        let newer = ReleaseCache(latest: "0.15.1", checkedAt: ago(0.5), attemptedAt: ago(0.5))
        #expect(!ReleaseRules.shouldFetch(newer, current: Version(0, 16, 0), maxAge: ReleaseRules.panelMaxAge, now: now))
        #expect(ReleaseRules.shouldFetch(failed, current: Version(0, 15, 1), maxAge: ReleaseRules.panelMaxAge, force: true, now: now))
    }

    @Test func available() {
        #expect(ReleaseRules.available(ReleaseCache(latest: "0.16.0"), current: Version(0, 15, 1)) == Version(0, 16, 0))
        #expect(ReleaseRules.available(ReleaseCache(latest: "0.15.1"), current: Version(0, 15, 1)) == nil)
        #expect(ReleaseRules.available(ReleaseCache(latest: "0.15.0"), current: Version(0, 15, 1)) == nil)
        #expect(ReleaseRules.available(ReleaseCache(latest: "0.16.0"), current: nil) == nil)
    }
}

@MainActor
struct ReleaseCheckerTests {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vl-update-\(UUID().uuidString).json")

    final class Fetches { var count = 0; var answer: String? = "v0.16.0" }
    final class Clock { var now = date("2026-10-07T12:00:00Z") }

    func checker(_ fetches: Fetches, _ clock: Clock) -> (ReleaseChecker, () -> [Version]) {
        var notified: [Version] = []
        let checker = ReleaseChecker(cacheURL: url, fetch: { fetches.count += 1; return fetches.answer }, now: { clock.now })
        checker.onNewRelease = { notified.append($0) }
        return (checker, { notified })
    }

    @Test func findsANewReleaseAndNotifiesOnce() async {
        let fetches = Fetches(), clock = Clock()
        let (checker, notified) = checker(fetches, clock)
        await checker.check(current: Version(0, 15, 1), maxAge: ReleaseRules.backgroundMaxAge)
        #expect(checker.available(current: Version(0, 15, 1)) == Version(0, 16, 0))
        #expect(notified() == [Version(0, 16, 0)])
        clock.now = clock.now.addingTimeInterval(2 * 3600)
        await checker.check(current: Version(0, 15, 1), maxAge: ReleaseRules.panelMaxAge)
        #expect(fetches.count == 2)
        #expect(notified() == [Version(0, 16, 0)])
    }

    @Test func keepsItsCache() async {
        let fetches = Fetches(), clock = Clock()
        let (checker, _) = checker(fetches, clock)
        await checker.check(current: Version(0, 15, 1), maxAge: ReleaseRules.backgroundMaxAge)
        let again = ReleaseChecker(cacheURL: url, fetch: { nil })
        #expect(again.cache.latest == "0.16.0")
        #expect(again.cache.checkedAt == clock.now)
        #expect(again.cache.notified == "0.16.0")
    }

    @Test func aFailedCheckWaitsAnHour() async {
        let fetches = Fetches(), clock = Clock()
        fetches.answer = nil
        let (checker, notified) = checker(fetches, clock)
        await checker.check(current: Version(0, 15, 1), maxAge: ReleaseRules.panelMaxAge)
        #expect(checker.cache.checkedAt == nil)
        #expect(checker.cache.attemptedAt == clock.now)
        clock.now = clock.now.addingTimeInterval(30 * 60)
        await checker.check(current: Version(0, 15, 1), maxAge: ReleaseRules.panelMaxAge)
        #expect(fetches.count == 1)
        clock.now = clock.now.addingTimeInterval(31 * 60)
        fetches.answer = "v0.15.1"
        await checker.check(current: Version(0, 15, 1), maxAge: ReleaseRules.panelMaxAge)
        #expect(fetches.count == 2)
        #expect(checker.available(current: Version(0, 15, 1)) == nil)
        #expect(notified().isEmpty)
    }
}
