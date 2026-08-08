// swift-tools-version:6.1
// 6.1 is required for package traits (`traits:` below), which upstream uses to
// gate the Zenzai/llama.cpp dependency. 5.10 rejects that API.
import Foundation
import PackageDescription

// No `platforms:` declaration: SPM's platform list only describes Apple
// deployment targets, and an empty array is rejected outright
// ("supported platforms can't be empty"). Ohagey targets Windows x64 only
// (decision 0018), which SPM expresses through the toolchain, not this field.

// ── Building against a local checkout of the converter ─────────────────────
//
// Set OHAGEY_CONVERTER_PATH to a clone of the fork and the build uses that
// instead of the pinned revision. The directory has to be named
// AzooKeyKanaKanjiConverter: SwiftPM takes a path dependency's identity from
// the last path component, not from the manifest, so any other name fails
// with "unknown package" against every target that depends on it.
//
// This exists because there is no other way to change the converter and see
// the result. SwiftPM treats `.build/checkouts/` as a cache it owns: editing a
// file in there and rebuilding prints "Build complete" in under a second and
// links the previous binary. Decision 0034 recorded a set of measurements that
// had to be retracted for exactly that reason — they were taken against a
// source change that was never compiled.
//
// Only for development. Nothing ships from a path dependency: the variable is
// unset in CI and on any machine that has not deliberately set it, and
// `swift build` then resolves the pinned revision as before. It is safe to
// have here in a way `OHAGEY_MODEL_PATH` is not (decision 0008), because this
// is read by the build system on a developer's machine rather than by a
// shipped process that inherits a caller's environment.
let converterCheckout = ProcessInfo.processInfo.environment["OHAGEY_CONVERTER_PATH"]
    .flatMap { $0.isEmpty ? nil : $0 }

let package = Package(
    name: "OhageyEngine",
    products: [
        .executable(name: "OhageyEngine", targets: ["OhageyEngine"]),
        // A diagnostic, not part of the product. See Sources/OhageyLMProbe.
        .executable(name: "OhageyLMProbe", targets: ["OhageyLMProbe"]),
        // Also a diagnostic. See Sources/OhageyLMTrain.
        .executable(name: "OhageyLMTrain", targets: ["OhageyLMTrain"]),
    ],
    dependencies: [
        // AzooKeyKanaKanjiConverter — a fork of the 0.8.5 tag, pinned by commit
        // (decision 0034). Upstream disables personalisation on Windows; the
        // fork changes only Package.swift, with no source differences at all,
        // and depends on a fork of SwiftyMarisa carrying two bug fixes. Pinned
        // by revision rather than branch so the build stays reproducible, and
        // still tied to llama.cpp b4846 exactly as decision 0028 requires — the
        // fork point is 0.8.5 itself.
        converterCheckout.map {
            Package.Dependency.package(path: $0, traits: ["Zenzai"])
        } ?? .package(
            url: "https://github.com/C0uki/AzooKeyKanaKanjiConverter",
            revision: "fdaaa9a1dff92109e7b1d88521fe8993b14df2a3",
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
        // A diagnostic that loads the two n-gram models and prints what they
        // actually say. It exists because personalisation's damage was
        // explained from reading `ZenzContext` and arithmetic on assumed
        // smoothing values, and that explanation needs checking against real
        // numbers (decision 0034, addendum 12).
        //
        // Deliberately not a mode of the engine: it has no business being
        // reachable from a running IME, and the installer ships
        // OhageyEngine.exe alone.
        // Trains an n-gram model from a text file, so a base model can be
        // built here rather than taken from a repository that publishes four
        // of the five files and no licence (decision 0034, option 3).
        //
        // Same reasoning as OhageyLMProbe for keeping it out of the engine.
        .executableTarget(
            name: "OhageyLMTrain",
            dependencies: [
                .product(name: "EfficientNGram", package: "AzooKeyKanaKanjiConverter"),
            ],
            path: "Sources/OhageyLMTrain",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // EfficientNGram reaches llama.cpp through a package built
                // with C++ interop, and Swift will not import such a module
                // without it.
                .interoperabilityMode(.Cxx)
            ]
        ),
        .executableTarget(
            name: "OhageyLMProbe",
            dependencies: [
                .product(name: "EfficientNGram", package: "AzooKeyKanaKanjiConverter"),
            ],
            path: "Sources/OhageyLMProbe",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // EfficientNGram comes from a package built with C++ interop
                // (it reaches llama.cpp through the same tree), and Swift will
                // not import such a module without it.
                .interoperabilityMode(.Cxx)
            ]
        ),
        .executableTarget(
            name: "OhageyEngine",
            dependencies: [
                .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter"),
                // trainNGram, for building the personal language model out of
                // what the user has committed (decision 0034). The converter
                // takes trained trie files but offers no way to produce them.
                .product(name: "EfficientNGram", package: "AzooKeyKanaKanjiConverter"),
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
            ],
            linkerSettings: [
                // Delay-load llama.dll so the engine can choose which backend's
                // copy to load (decision 0028).
                //
                // Without this the DLL is an ordinary static import, resolved
                // by the loader before any Ohagey code runs — so nothing the
                // engine does about search paths can matter. Delay-loading
                // moves the resolution to the first call into llama, which is
                // after BackendLoader has said where to look.
                //
                // `delayimp.lib` provides the stub that performs that load;
                // /DELAYLOAD without it does not link.
                //
                // unsafeFlags is acceptable here because this is a root
                // package. It would stop anyone depending on the engine as a
                // library, which nothing does.
                .unsafeFlags([
                    "-Xlinker", "/DELAYLOAD:llama.dll",
                    "-Xlinker", "delayimp.lib",
                ], .when(platforms: [.windows]))
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
