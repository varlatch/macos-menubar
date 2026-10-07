import Foundation

/// How the app starts at login, decided by where it is installed.
///
/// A Homebrew install runs from a versioned Cellar directory
/// (`<prefix>/Cellar/varlatch-menubar/<version>/Varlatch.app`), even when
/// opened through a link, and `brew upgrade` removes that directory. A login
/// item registered for it would point at nothing after the next upgrade, so
/// a Homebrew install starts at login through a user LaunchAgent that opens
/// the stable `<prefix>/opt/varlatch-menubar/Varlatch.app` instead. Anywhere
/// else, the app registers itself as a login item.
public enum LaunchAtLoginMethod: Equatable {
    case loginItem
    case launchAgent(appPath: String)

    public static let formula = "varlatch-menubar"
    public static let agentLabel = "com.varlatch.menubar.login"

    /// - Parameter exists: whether a path exists (the opt link is checked).
    public static func method(forBundlePath bundlePath: String,
                              exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Self {
        let marker = "/Cellar/\(formula)/"
        guard let range = bundlePath.range(of: marker) else { return .loginItem }
        let prefix = String(bundlePath[..<range.lowerBound])
        let rest = bundlePath[range.upperBound...]
        // <version>/Varlatch.app
        guard let slash = rest.firstIndex(of: "/") else { return .loginItem }
        let appName = rest[rest.index(after: slash)...]
        let optPath = "\(prefix)/opt/\(formula)/\(appName)"
        return exists(optPath) ? .launchAgent(appPath: optPath) : .loginItem
    }

    /// The LaunchAgent that opens the app at login.
    public static func agentPlist(appPath: String) -> Data {
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/usr/bin/open", "-a", appPath],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "AssociatedBundleIdentifiers": ["com.varlatch.menubar"],
        ]
        // A dictionary of property list types always serializes.
        return try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    public static func agentURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }
}
