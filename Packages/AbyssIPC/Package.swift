// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AbyssIPC",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AbyssIPC", type: .static, targets: ["AbyssIPC"]),
    ],
    dependencies: [
        .package(path: "../AbyssCore"),
    ],
    targets: [
        .target(name: "AbyssIPC", dependencies: ["AbyssCore"]),
        .testTarget(name: "AbyssIPCTests", dependencies: ["AbyssIPC", "AbyssCore"]),
    ],
    swiftLanguageModes: [.v6]
)
