// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "RiftFilterRuntime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RiftFilterRuntime", type: .static, targets: ["RiftFilterRuntime"]),
    ],
    dependencies: [
        .package(path: "../RiftCore"),
        .package(path: "../RiftIPC"),
    ],
    targets: [
        .target(name: "RiftFilterRuntime", dependencies: ["RiftCore", "RiftIPC"]),
        .testTarget(
            name: "RiftFilterRuntimeTests",
            dependencies: ["RiftFilterRuntime", "RiftCore", "RiftIPC"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
