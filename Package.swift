// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "msl",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "msl", targets: ["msl"]),
        .executable(name: "msld", targets: ["msld"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.3"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.10.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.1"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
        .package(url: "https://github.com/apple/containerization.git", exact: "0.46.0"),
    ],
    targets: [
        // CLI parsing, messages, registry model, msl<->msld IPC. No heavy deps: `msl` links only this.
        .target(name: "CMSLSupport"),
        .target(name: "MSLCore", dependencies: ["CMSLSupport"], swiftSettings: v5),
        // Generated from proto/msl/v1/msl.proto by scripts/gen-proto.sh (checked in).
        .target(
            name: "MSLProtocol",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
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
            swiftSettings: v5
        ),
        .executableTarget(name: "msld", dependencies: ["MSLService"], swiftSettings: v5),
        .executableTarget(name: "msl", dependencies: ["MSLCore"], swiftSettings: v5),
        .testTarget(name: "MSLCoreTests", dependencies: ["MSLCore"], swiftSettings: v5),
    ]
)
