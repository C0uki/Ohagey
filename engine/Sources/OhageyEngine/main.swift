// OhageyEngine
//
// Single shared conversion server process (decisions 0004 / 0005).
// Launched on-demand by a TSF client (decision 0015); listens on a
// session-ID-scoped named pipe (decision 0006) speaking length-prefixed
// Protobuf (decision 0007); wraps AzooKeyKanaKanjiConverter + Zenzai for the
// actual conversion (decision 0001).
//
// STATUS: scaffold. Startup is wired up to the point where the pipe would be
// created; the accept loop and request routing are still TODO, and none of
// this has been compiled (no Swift toolchain in the authoring environment —
// see docs/local-setup.md).

import Foundation
import OhageyEngineCore

// NOTE: this file is `main.swift`, so it is top-level code and must not carry
// the `@main` attribute — Swift rejects the two together. The entry point is
// the `OhageyEngineMain.main()` call at the bottom of the file.
enum OhageyEngineMain {
    static func main() {
        do {
            try EnginePaths.ensureUserDataDirectoryExists()
        } catch {
            // Without this directory learning and the user dictionary cannot be
            // persisted, but conversion itself still works — keep going.
            log("could not create \(EnginePaths.userDataDirectory.path): \(error)")
        }

        let settings = EngineSettings.load()
        log("settings loaded (learning=\(settings.learningEnabled), backend=\(settings.backend.rawValue))")
        log(EnginePaths.isModelAvailable
            ? "Zenzai model found at \(EnginePaths.modelURL.path)"
            // Not an error: the install is allowed to complete without the
            // model, and conversion degrades to the dictionary path (0008).
            : "Zenzai model missing — falling back to dictionary-only conversion")

        #if os(Windows)
        do {
            let sessionId = try PipeServer.currentSessionId()
            let name = PipeServer.pipeName(sessionId: sessionId)
            log("pipe name: \(name)")
            // TODO: create the first instance, then run the accept loop:
            //   let handle = try PipeServer.createPipeInstance(name: name)
            //   ... ConnectNamedPipe / per-connection read loop / idle timeout.
            log("accept loop not implemented yet — exiting.")
        } catch {
            log("fatal: \(error)")
            exit(1)
        }
        #else
        // The engine only ever ships on Windows x64 (decision 0018). Building
        // on another platform is useful for type-checking the portable pieces
        // (Framing, settings, conversion mapping), so fail soft rather than
        // refusing to build.
        log("not a Windows host — pipe server unavailable; scaffold exits.")
        #endif
    }

    private static func log(_ message: String) {
        // Console logging only. No telemetry, no crash reporting, nothing
        // leaves the machine (decision 0016).
        print("OhageyEngine: \(message)")
    }
}

OhageyEngineMain.main()

// TODO (implementation phase, tracked in docs/roadmap.md):
//  1. Generate the Protobuf types (Scripts/generate-proto.sh) and enable the
//     swift-protobuf dependency in Package.swift.
//  2. RequestRouter: decode Request -> dispatch to ConversionService -> encode
//     Response, preserving request_id so clients can pipeline.
//  3. Accept loop in PipeServer, one pipe instance per client.
//  4. Idle-timeout self-termination once the connection count has been zero for
//     `settings.idleTimeoutSeconds` (decision 0015).
//  5. Settings hot-reload via file/registry watching (decision 0014).
