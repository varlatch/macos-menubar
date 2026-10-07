import Foundation

/// `Tests/fake-varlatch` in a throwaway directory: the status it reports,
/// how its sign-ins end, and what it was asked.
struct FakeCLI {
    static let path = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/fake-varlatch").path

    let dir: URL

    init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vl-fake-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    var environment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": dir.path, "FAKE_VARLATCH_DIR": dir.path]
    }

    func setStatus(_ json: String) {
        try! json.write(to: dir.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
    }

    func setProbe(_ json: String) {
        try! json.write(to: dir.appendingPathComponent("probe.json"), atomically: true, encoding: .utf8)
    }

    /// Variables the fake reads on every call, such as FAKE_LOGIN_RC.
    func set(_ variables: [String: String]) {
        let text = variables.map { "export \($0.key)=\"\($0.value)\"" }.joined(separator: "\n") + "\n"
        try! text.write(to: dir.appendingPathComponent("fake.env"), atomically: true, encoding: .utf8)
    }

    var calls: [String] {
        let text = (try? String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    static func status(_ servers: String...) -> String {
        #"{"version":1,"servers":["# + servers.joined(separator: ",") + #"],"repo":null}"#
    }

    static func server(_ url: String, expiresIn hours: Double = 10, lifetime: Double = 12,
                       expiring: Bool? = false, expired: Bool = false) -> String {
        let now = Date()
        let expires = now.addingTimeInterval(hours * 3600)
        let issued = expires.addingTimeInterval(-lifetime * 3600)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiringField = expiring.map { #","expiring":\#($0)"# } ?? ""
        return #"{"server":"\#(url)","name":null,"issuedAt":"\#(f.string(from: issued))","expiresAt":"\#(f.string(from: expires))","credentialId":"crd_x","expired":\#(expired)\#(expiringField)}"#
    }
}
