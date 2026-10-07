import Foundation
import Testing
@testable import VarlatchKit

struct CLILocatorTests {
    @Test func prefersHomebrewOnAppleSilicon() {
        let locator = CLILocator(home: "/Users/me") { $0 == "/opt/homebrew/bin/varlatch" || $0 == "/usr/local/bin/varlatch" }
        #expect(locator.resolve() == .found("/opt/homebrew/bin/varlatch"))
    }

    @Test func findsTheUserInstall() {
        let locator = CLILocator(home: "/Users/me") { $0 == "/Users/me/.local/bin/varlatch" }
        #expect(locator.resolve() == .found("/Users/me/.local/bin/varlatch"))
    }

    @Test func reportsWhereItLooked() {
        let locator = CLILocator(home: "/Users/me") { _ in false }
        #expect(locator.resolve() == .notFound(searched: [
            "/opt/homebrew/bin/varlatch", "/usr/local/bin/varlatch", "/Users/me/.local/bin/varlatch",
        ]))
    }

    @Test func usesTheSetPathOnly() {
        let locator = CLILocator(override: " ~/bin/varlatch ", home: "/Users/me") { $0 == "/opt/homebrew/bin/varlatch" }
        #expect(locator.resolve() == .overrideUnusable("/Users/me/bin/varlatch"))
        let found = CLILocator(override: "~/bin/varlatch", home: "/Users/me") { $0 == "/Users/me/bin/varlatch" }
        #expect(found.resolve() == .found("/Users/me/bin/varlatch"))
    }

    @Test func emptySetPathMeansAutomatic() {
        let locator = CLILocator(override: "  ", home: "/Users/me") { $0 == "/usr/local/bin/varlatch" }
        #expect(locator.resolve() == .found("/usr/local/bin/varlatch"))
    }

    @Test func pathForFinderLaunchedApps() {
        let locator = CLILocator(home: "/Users/me")
        let env = locator.environment(for: "/Users/me/.local/bin/varlatch",
                                      base: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/me"])
        #expect(env["PATH"] == "/Users/me/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(env["HOME"] == "/Users/me")
    }

    @Test func pathWithoutRepeats() {
        let locator = CLILocator(home: "/Users/me")
        let env = locator.environment(for: "/opt/homebrew/bin/varlatch", base: ["PATH": "/opt/homebrew/bin:/usr/bin"])
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/Users/me/.local/bin:/usr/bin")
    }
}

struct LaunchAtLoginTests {
    @Test func homebrewInstallUsesTheOptLink() {
        let method = LaunchAtLoginMethod.method(
            forBundlePath: "/opt/homebrew/Cellar/varlatch-menubar/0.1.0/Varlatch.app") { $0 == "/opt/homebrew/opt/varlatch-menubar/Varlatch.app" }
        #expect(method == .launchAgent(appPath: "/opt/homebrew/opt/varlatch-menubar/Varlatch.app"))
        let intel = LaunchAtLoginMethod.method(
            forBundlePath: "/usr/local/Cellar/varlatch-menubar/HEAD-5bf2e94/Varlatch.app") { _ in true }
        #expect(intel == .launchAgent(appPath: "/usr/local/opt/varlatch-menubar/Varlatch.app"))
    }

    @Test func elsewhereALoginItem() {
        #expect(LaunchAtLoginMethod.method(forBundlePath: "/Applications/Varlatch.app") { _ in true } == .loginItem)
        // No opt link: not a Homebrew keg after all.
        #expect(LaunchAtLoginMethod.method(
            forBundlePath: "/opt/homebrew/Cellar/varlatch-menubar/0.1.0/Varlatch.app") { _ in false } == .loginItem)
    }

    @Test func agentOpensTheApp() throws {
        let data = LaunchAtLoginMethod.agentPlist(appPath: "/opt/homebrew/opt/varlatch-menubar/Varlatch.app")
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "com.varlatch.menubar.login")
        #expect(plist["ProgramArguments"] as? [String] == ["/usr/bin/open", "-a", "/opt/homebrew/opt/varlatch-menubar/Varlatch.app"])
        #expect(plist["RunAtLoad"] as? Bool == true)
    }
}
