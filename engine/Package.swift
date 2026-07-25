// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OhageyEngine",
    platforms: [
        // Windows toolchain target; platform list here is informational for SPM tooling.
    ],
    products: [
        .executable(name: "OhageyEngine", targets: ["OhageyEngine"])
    ],
    dependencies: [
        // AzooKeyKanaKanjiConverter — pinned to avoid minor-version breaking changes,
        // per upstream's own recommendation (pre-1.0 API).
        .package(
            url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter",
            .upToNextMinor(from: "0.8.0"),
            traits: ["Zenzai"]
        ),
        // Runtime for the types generated from ohagey.proto (decision 0007).
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    ],
    targets: [
        .executableTarget(
            name: "OhageyEngine",
            dependencies: [
                .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter"),
                "OhageyEngineProto",
            ],
            path: "Sources/OhageyEngine"
        ),
        .target(
            name: "OhageyEngineProto",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/OhageyEngineProto"
            // Holds ohagey.proto and the ohagey.pb.swift generated from it by
            // Scripts/generate-proto.sh. The generated file is committed, so a
            // plain `swift build` does not need protoc.
        ),
    ]
)
