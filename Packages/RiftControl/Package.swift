// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "RiftControl",
    platforms: [.macOS(.v14)],
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
            dependencies: ["RiftCore", "RiftIPC", .product(name: "GRDB", package: "GRDB.swift")]
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
