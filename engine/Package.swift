// swift-tools-version:6.1
// 6.1 is required for package traits (`traits:` below), which upstream uses to
// gate the Zenzai/llama.cpp dependency. 5.10 rejects that API.
import PackageDescription

// No `platforms:` declaration: SPM's platform list only describes Apple
// deployment targets, and an empty array is rejected outright
// ("supported platforms can't be empty"). Ohagey targets Windows x64 only
// (decision 0018), which SPM expresses through the toolchain, not this field.
let package = Package(
    name: "OhageyEngine",
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
        // Portable pieces with no Windows, Protobuf or converter dependencies:
        // framing and settings. Split out of the executable so they can be unit
        // tested — SwiftPM cannot reliably host tests against an executable
        // target, and keeping this free of C++ interop makes the test build
        // cheap and platform-independent.
        .target(
            name: "OhageyEngineCore",
            path: "Sources/OhageyEngineCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "OhageyEngineCoreTests",
            dependencies: ["OhageyEngineCore"],
            path: "Tests/OhageyEngineCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "OhageyEngine",
            dependencies: [
                .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter"),
                "OhageyEngineCore",
                "OhageyEngineProto",
            ],
            path: "Sources/OhageyEngine",
            swiftSettings: [
                // Tools version 6.x would otherwise default to the Swift 6
                // language mode, whose strict concurrency checking turns a pile
                // of Sendable diagnostics into hard errors before any of this
                // code has run once. Staying on v5 keeps the tools-version bump
                // (needed purely for `traits:`) from dragging a concurrency
                // migration along with it.
                // TODO: migrate to .v6 once the engine actually builds and runs.
                .swiftLanguageMode(.v5),
                // The Zenzai trait builds KanaKanjiConverterModule and friends
                // with C++ interop (they wrap llama.cpp), and Swift refuses to
                // import such a module from a compilation that does not enable
                // it too. This must match upstream or every import fails.
                .interoperabilityMode(.Cxx)
            ]
        ),
        .target(
            name: "OhageyEngineProto",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                // For the wire <-> engine model mapping in WireMapping.swift.
                "OhageyEngineCore",
            ],
            path: "Sources/OhageyEngineProto",
            // The schema and its docs live beside the generated code but are not
            // themselves build inputs; without this SPM warns about "unhandled"
            // files on every build.
            exclude: [
                "ohagey.proto",
                "README.md",
            ],
            // Holds ohagey.proto and the ohagey.pb.swift generated from it by
            // Scripts/generate-proto.sh. The generated file is committed, so a
            // plain `swift build` does not need protoc.
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // The mapping in OhageyEngineProto is where wire-shaped values become
        // engine values, so it is where absent oneofs and out-of-range counts
        // have to be handled. Worth testing directly; it needs SwiftProtobuf
        // but no C++ interop, so the test build stays cheap.
        .testTarget(
            name: "OhageyEngineProtoTests",
            dependencies: ["OhageyEngineProto"],
            path: "Tests/OhageyEngineProtoTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
