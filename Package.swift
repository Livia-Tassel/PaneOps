// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "PaneOps",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agent-sentinel", targets: ["SentinelCLI"]),
        .executable(name: "sentinel-monitor", targets: ["SentinelMonitor"]),
        .executable(name: "SentinelApp", targets: ["SentinelApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "SentinelShared",
            dependencies: [],
            path: "Shared"
        ),
        .executableTarget(
            name: "SentinelCLI",
            dependencies: [
                "SentinelShared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "CLI"
        ),
        .executableTarget(
            name: "SentinelMonitor",
            dependencies: ["SentinelShared"],
            path: "Monitor"
        ),
        .executableTarget(
            name: "SentinelApp",
            dependencies: ["SentinelShared"],
            path: "App",
            resources: [.copy("../Resources/Info.plist")]
        ),
        .testTarget(
            name: "SentinelSharedTests",
            dependencies: ["SentinelShared"]
        ),
        .testTarget(
            name: "SentinelCLITests",
            dependencies: ["SentinelCLI", "SentinelShared"]
        ),
    ]
)
