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
