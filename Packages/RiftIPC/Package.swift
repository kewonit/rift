// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RiftIPC",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RiftIPC", type: .static, targets: ["RiftIPC"]),
    ],
    dependencies: [
        .package(path: "../RiftCore"),
    ],
    targets: [
        .target(name: "RiftIPC", dependencies: ["RiftCore"]),
        .testTarget(name: "RiftIPCTests", dependencies: ["RiftIPC", "RiftCore"]),
    ],
    swiftLanguageModes: [.v6]
)
