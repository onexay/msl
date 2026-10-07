// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "msl",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "msl", targets: ["msl"]),
        .executable(name: "msld", targets: ["msld"]),
        .executable(name: "msl-portd", targets: ["msl-portd"]),
        .executable(name: "msl-fileviewd", targets: ["msl-fileviewd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.3"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.10.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.1"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
        .package(url: "https://github.com/apple/containerization.git", exact: "0.48.0"),
    ],
    targets: [
        // CLI parsing, messages, registry model, msl<->msld IPC. No heavy deps: `msl` links only this.
        .target(name: "CMSLSupport", path: "core/CMSLSupport"),
        .target(name: "MSLCore", dependencies: ["CMSLSupport"], path: "core/MSLCore",
                swiftSettings: v5, linkerSettings: [.linkedFramework("SystemConfiguration")]),
        // Generated from core/proto/msl/v1/msl.proto by scripts/gen-proto.sh (checked in).
        .target(
            name: "MSLProtocol",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "core/MSLProtocol",
            swiftSettings: v5
        ),
        // The service: VM lifecycle, guest RPC, session bridging.
        .target(
            name: "MSLService",
            dependencies: [
                "MSLCore", "MSLProtocol",
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
            ],
            path: "host/MSLService",
            swiftSettings: v5
        ),
        .executableTarget(name: "msld", dependencies: ["MSLService"], path: "host/msld", exclude: ["msld.entitlements"], swiftSettings: v5),
        .executableTarget(name: "msl", dependencies: ["MSLCore"], path: "host/msl", swiftSettings: v5),
        // localhost forwarding's relay (WSL's wslrelay.exe), started by msld.
        .executableTarget(name: "msl-portd", dependencies: ["MSLCore"], path: "host/msl-portd", swiftSettings: v5),
        // The ~/.msl/distros view's relay (RPCFilter + copying), started by msld.
        .executableTarget(name: "msl-fileviewd", dependencies: ["MSLCore"], path: "host/msl-fileviewd", swiftSettings: v5),
        .testTarget(name: "MSLCoreTests", dependencies: ["MSLCore"], path: "tests/MSLCoreTests", swiftSettings: v5),
    ]
)
