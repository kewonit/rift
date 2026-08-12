// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "AbyssControl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AbyssControl", type: .static, targets: ["AbyssControl"]),
    ],
    dependencies: [
        .package(path: "../AbyssCore"),
        .package(path: "../AbyssIPC"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
    ],
    targets: [
        .target(
            name: "AbyssControl",
            dependencies: ["AbyssCore", "AbyssIPC", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "AbyssControlTests",
            dependencies: [
                "AbyssControl",
                "AbyssCore",
                "AbyssIPC",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
