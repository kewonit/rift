// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "AbyssFilterRuntime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AbyssFilterRuntime", type: .static, targets: ["AbyssFilterRuntime"]),
    ],
    dependencies: [
        .package(path: "../AbyssCore"),
        .package(path: "../AbyssIPC"),
    ],
    targets: [
        .target(name: "AbyssFilterRuntime", dependencies: ["AbyssCore", "AbyssIPC"]),
        .testTarget(
            name: "AbyssFilterRuntimeTests",
            dependencies: ["AbyssFilterRuntime", "AbyssCore", "AbyssIPC"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
