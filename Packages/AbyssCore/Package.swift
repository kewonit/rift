// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AbyssCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AbyssCore", type: .static, targets: ["AbyssCore"]),
    ],
    targets: [
        .target(name: "AbyssCore"),
        .testTarget(
            name: "AbyssCoreTests",
            dependencies: ["AbyssCore"],
            resources: [.process("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
