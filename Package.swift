// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeAutoSwitch",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeAutoSwitch", targets: ["ClaudeAutoSwitch"]),
        .library(name: "AutoSwitchCore", targets: ["AutoSwitchCore"]),
        .library(name: "AutoSwitchEngine", targets: ["AutoSwitchEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    ],
    targets: [
        // Foundation only: models, derivations, localization, config document handling.
        .target(name: "AutoSwitchCore", resources: [.process("Resources")]),
        // The proxy: accounts, OAuth, quota, rotation, the local HTTP server and its control plane.
        .target(name: "AutoSwitchEngine", dependencies: [
            "AutoSwitchCore",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ]),
        .executableTarget(name: "ClaudeAutoSwitch", dependencies: ["AutoSwitchCore", "AutoSwitchEngine"]),
        .testTarget(name: "AutoSwitchCoreTests", dependencies: ["AutoSwitchCore"]),
        .testTarget(name: "AutoSwitchEngineTests", dependencies: ["AutoSwitchEngine", "AutoSwitchCore"]),
    ],
    swiftLanguageModes: [.v6]
)
