// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "RiftControl",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RiftControl", type: .static, targets: ["RiftControl"]),
    ],
    dependencies: [
        .package(path: "../RiftCore"),
        .package(path: "../RiftIPC"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
    ],
    targets: [
        .target(
            name: "RiftControl",
            dependencies: [
                "RiftCore",
                "RiftIPC",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "RiftControlTests",
            dependencies: [
                "RiftControl",
                "RiftCore",
                "RiftIPC",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
