import Foundation
import Testing
@testable import VarlatchKit

func date(_ iso: String) -> Date { ServerStatus.date(iso)! }

struct StatusDocumentTests {
    @Test func readsTheCLIDocument() throws {
        let doc = try #require(StatusDocument.parse("""
            {"version": 1,
             "servers": [{"server": "https://vl.example.com", "name": null,
                          "issuedAt": "2026-10-07T06:35:12.544Z", "expiresAt": "2026-10-07T18:35:12.470Z",
                          "credentialId": "crd_1", "expired": false, "expiring": false}],
             "repo": null}
            """))
        #expect(doc.version == 1)
        let s = try #require(doc.servers.first)
        #expect(s.server == "https://vl.example.com")
        #expect(s.name == nil)
        #expect(s.issuedAt == date("2026-10-07T06:35:12.544Z"))
        #expect(abs(s.expiresAt!.timeIntervalSince(s.issuedAt!) - 43199.926) < 0.001)
        #expect(s.credentialId == "crd_1")
        #expect(s.expired == false)
        #expect(s.expiring == false)
        #expect(s.reportsExpiring)
        #expect(s.probe == nil)
    }

    @Test func everythingButTheServerMayBeNull() throws {
        let doc = try #require(StatusDocument.parse("""
            {"version":1,"servers":[{"server":"https://vl.example.com","name":null,"issuedAt":null,
             "expiresAt":null,"credentialId":null,"expired":null,"expiring":null}],"repo":null}
            """))
        let s = try #require(doc.servers.first)
        #expect(s.issuedAt == nil && s.expiresAt == nil && s.expired == nil && s.expiring == nil)
        #expect(s.reportsExpiring)
        #expect(s.health(now: Date()) == .ok)
        #expect(Sessions.detail(for: s) == "Logged in, no expiry recorded")
    }

    @Test func olderCLIsLeaveOutExpiring() throws {
        let doc = try #require(StatusDocument.parse("""
            {"servers":[{"server":"https://a.example.com","issuedAt":"2026-10-07T00:00:00Z",
             "expiresAt":"2026-10-07T10:00:00Z","expired":false}]}
            """))
        let s = try #require(doc.servers.first)
        #expect(!s.reportsExpiring)
        // 10-hour lifetime: expiring with under 2 hours left.
        #expect(s.health(now: date("2026-10-07T07:59:00Z")) == .ok)
        #expect(s.health(now: date("2026-10-07T08:01:00Z")) == .expiring)
        #expect(s.health(now: date("2026-10-07T10:00:00Z")) == .expired)
    }

    @Test func probeResults() throws {
        let doc = try #require(StatusDocument.parse("""
            {"version":1,"servers":[
              {"server":"https://a.example.com","probe":{"state":"valid","detail":null}},
              {"server":"https://b.example.com","probe":{"state":"invalid","detail":"401 UNAUTHENTICATED"}},
              {"server":"https://c.example.com","probe":{"state":"unreachable","detail":"ECONNREFUSED"}},
              {"server":"https://d.example.com","probe":{"state":"brand-new","detail":null}}]}
            """))
        #expect(doc.servers.map { $0.probe?.state } == [.valid, .invalid, .unreachable, .unreachable])
        #expect(doc.servers[1].probe?.detail == "401 UNAUTHENTICATED")
    }

    @Test func noCredentials() throws {
        #expect(try #require(StatusDocument.parse(#"{"version":1,"servers":[],"repo":null}"#)).servers.isEmpty)
    }

    @Test func notADocument() {
        #expect(StatusDocument.parse("No stored credentials.") == nil)
        #expect(StatusDocument.parse(#"{"servers":[{"name":"no server"}]}"#) == nil)
    }

    @Test func badTimestampsReadAsMissing() throws {
        let doc = try #require(StatusDocument.parse(#"{"servers":[{"server":"https://a","expiresAt":"tomorrow"}]}"#))
        #expect(doc.servers[0].expiresAt == nil)
    }
}

struct SessionRuleTests {
    let issued = date("2026-10-07T06:00:00Z")
    let expires = date("2026-10-07T18:00:00Z")

    @Test func theCLIDecidesExpiring() {
        let s = ServerStatus(server: "https://a", issuedAt: issued, expiresAt: expires, expired: false, expiring: true)
        #expect(s.health(now: date("2026-10-07T07:00:00Z")) == .expiring)
    }

    @Test func expiredWinsAndTimePassingCounts() {
        let s = ServerStatus(server: "https://a", issuedAt: issued, expiresAt: expires, expired: false, expiring: false)
        #expect(s.health(now: date("2026-10-07T17:59:59Z")) == .ok)
        #expect(s.health(now: date("2026-10-07T18:00:00Z")) == .expired)
        let flagged = ServerStatus(server: "https://a", expired: true)
        #expect(flagged.health() == .expired)
    }

    @Test func countdownText() {
        let now = date("2026-10-07T14:47:30Z")
        #expect(Sessions.remaining(until: expires, now: now) == "3h 12m left")
        #expect(Sessions.remaining(until: date("2026-10-07T15:00:00Z"), now: now) == "12m left")
        #expect(Sessions.remaining(until: date("2026-10-07T14:47:40Z"), now: now) == "0m left")
        #expect(Sessions.remaining(until: now, now: now) == "expired")
        let s = ServerStatus(server: "https://a", issuedAt: issued, expiresAt: expires, expired: false, expiring: false)
        #expect(Sessions.detail(for: s, now: now) == "Logged in, 3h 12m left")
        #expect(Sessions.detail(for: s, now: expires) == "Session expired")
    }

    @Test func hosts() {
        #expect(Sessions.host(of: "https://vl.example.com") == "vl.example.com")
        #expect(Sessions.host(of: "https://vl.example.com:8443/varlatch/") == "vl.example.com:8443")
        #expect(Sessions.host(of: "vl.example.com") == "vl.example.com")
    }

    @Test func localhostFilter() {
        #expect(Sessions.isLocalhost("http://localhost:3000"))
        #expect(Sessions.isLocalhost("http://127.0.0.1:8080"))
        #expect(Sessions.isLocalhost("HTTP://LOCALHOST"))
        #expect(!Sessions.isLocalhost("https://vl.example.com"))
        #expect(!Sessions.isLocalhost("https://localhost.example.com"))
        #expect(!Sessions.isLocalhost("https://my-localhost.example.com"))
        let all = [ServerStatus(server: "http://localhost:3000"), ServerStatus(server: "https://vl.example.com")]
        #expect(Sessions.visible(all, showLocalhost: false).map(\.server) == ["https://vl.example.com"])
        #expect(Sessions.visible(all, showLocalhost: true).count == 2)
    }

    @Test func overallIsTheWorst() {
        let now = date("2026-10-07T12:00:00Z")
        let ok = ServerStatus(server: "https://a", expiresAt: date("2026-10-07T18:00:00Z"), expired: false, expiring: false)
        let soon = ServerStatus(server: "https://b", expiresAt: date("2026-10-07T13:00:00Z"), expired: false, expiring: true)
        let gone = ServerStatus(server: "https://c", expired: true)
        #expect(Sessions.overall([], now: now) == .signedOut)
        #expect(Sessions.overall([ok], now: now) == .ok)
        #expect(Sessions.overall([ok, soon], now: now) == .expiring)
        #expect(Sessions.overall([soon, gone, ok], now: now) == .expired)
        #expect(OverallState.ok.badge == .none)
        #expect(OverallState.expiring.badge == .warning)
        #expect([OverallState.signedOut, .expired, .cliMissing, .unsupported, .unavailable].allSatisfy { $0.badge == .error })
    }
}

struct ExpiryTrackerTests {
    let now = date("2026-10-07T12:00:00Z")
    func server(_ name: String, expiring: Bool = false, expired: Bool = false) -> ServerStatus {
        ServerStatus(server: "https://\(name).example.com", expiresAt: date("2026-10-07T13:00:00Z"),
                     expired: expired, expiring: expiring)
    }

    @Test func oncePerTransition() {
        var tracker = ExpiryTracker()
        #expect(tracker.update([server("a")], now: now).isEmpty)
        let first = tracker.update([server("a", expiring: true)], now: now)
        #expect(first.map(\.health) == [.expiring])
        #expect(first[0].body(now: now) == "Credential for a.example.com expires soon (1h 0m left).")
        #expect(tracker.update([server("a", expiring: true)], now: now).isEmpty)
        let expired = tracker.update([server("a", expired: true)], now: now)
        #expect(expired.map(\.health) == [.expired])
        #expect(expired[0].title == "Session expired")
        #expect(expired[0].body() == "Credential for a.example.com has expired. Log in again.")
        #expect(tracker.update([server("a", expired: true)], now: now).isEmpty)
    }

    @Test func renewedThenExpiringAgainNotifiesAgain() {
        var tracker = ExpiryTracker()
        _ = tracker.update([server("a", expiring: true)], now: now)
        #expect(tracker.update([server("a")], now: now).isEmpty)
        #expect(tracker.update([server("a", expiring: true)], now: now).count == 1)
    }

    @Test func eachServerOnItsOwn() {
        var tracker = ExpiryTracker()
        let events = tracker.update([server("a", expiring: true), server("b", expired: true), server("c")], now: now)
        #expect(events.map(\.server) == ["https://a.example.com", "https://b.example.com"])
        #expect(tracker.update([server("a", expiring: true), server("b", expired: true)], now: now).isEmpty)
    }
}

struct PreferencesTests {
    @Test func defaults() {
        let p = Preferences(UserDefaults(suiteName: "vl-test-\(UUID().uuidString)")!)
        #expect(p == Preferences())
        #expect(p.refreshInterval == 30)
        #expect(p.notifyExpiry && p.showWhenLoggedOut && p.launchAtLogin)
        #expect(!p.showLocalhost && !p.checkUpdates)
        #expect(p.sessionHours == 0 && p.ttlArguments.isEmpty)
    }

    @Test func limits() {
        #expect(Preferences(refreshInterval: 5).refreshInterval == 15)
        #expect(Preferences(sessionHours: 8).ttlArguments == ["--ttl", "28800"])
        #expect(Preferences(sessionHours: 24).ttlArguments == ["--ttl", "86400"])
        #expect(Preferences(sessionHours: 25).sessionHours == 0)
        #expect(Preferences(sessionHours: -1).ttlArguments.isEmpty)
    }

    @Test func readsStoredValues() {
        let defaults = UserDefaults(suiteName: "vl-test-\(UUID().uuidString)")!
        defaults.set(10, forKey: Preferences.Key.refreshInterval)
        defaults.set(true, forKey: Preferences.Key.showLocalhost)
        defaults.set(false, forKey: Preferences.Key.launchAtLogin)
        defaults.set("~/bin/varlatch", forKey: Preferences.Key.cliPath)
        let p = Preferences(defaults)
        #expect(p.refreshInterval == 15)
        #expect(p.showLocalhost && !p.launchAtLogin)
        #expect(p.cliPath == "~/bin/varlatch")
    }
}

struct VersionTests {
    @Test func parses() {
        #expect(Version.fromCLIOutput("varlatch 0.15.1 (migration 26)\n") == Version(0, 15, 1))
        #expect(Version.fromCLIOutput("Usage: varlatch <command>") == nil)
        #expect(Version("v0.16.0-rc.1") == Version(0, 16, 0, suffix: "rc.1"))
        #expect(Version("0.15") == nil)
        #expect(Version(0, 16, 0, suffix: "rc.1").description == "0.16.0-rc.1")
    }

    @Test func compares() {
        #expect(Version(0, 9, 9) < Version(0, 10, 0))
        #expect(Version(0, 14, 0) >= Version.deviceSignIn)
        #expect(Version(0, 13, 9) < Version.deviceSignIn)
        #expect(Version(0, 16, 0, suffix: "rc.1") < Version(0, 16, 0))
        #expect(Version(1, 0, 0) > Version(0, 99, 99))
    }
}
