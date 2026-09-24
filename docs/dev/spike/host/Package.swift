// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0
// Milestone 0 spike: boots the utility VM and bridges guest vsock ports to
// Unix sockets so scripts can drive the guest. Not the real msld.
import PackageDescription

let package = Package(
    name: "msl-spike",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", exact: "0.46.0"),
    ],
    targets: [
        .executableTarget(
            name: "msl-spike",
            dependencies: [.product(name: "ContainerizationEXT4", package: "containerization")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
