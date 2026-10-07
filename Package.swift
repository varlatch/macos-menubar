// swift-tools-version:5.9
// 5.9 so the Command Line Tools on macOS 13 can build it, not only Xcode.
import PackageDescription

let package = Package(
    name: "Varlatch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Varlatch", targets: ["Varlatch"]),
    ],
    targets: [
        // Everything that can be tested without a window server: the CLI
        // runner, status parsing, expiry rules, sign-in state machines.
        .target(name: "VarlatchKit"),
        // The SwiftUI app: menu bar extra, panel, settings, notifications.
        .executableTarget(name: "Varlatch", dependencies: ["VarlatchKit"]),
        .testTarget(name: "VarlatchKitTests", dependencies: ["VarlatchKit"]),
    ]
)
