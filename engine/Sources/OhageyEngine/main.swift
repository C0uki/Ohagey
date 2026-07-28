// OhageyEngine
//
// Single shared conversion server process (decisions 0004 / 0005).
// Launched on-demand by a TSF client (decision 0015); listens on a
// session-ID-scoped named pipe (decision 0006) speaking length-prefixed
// Protobuf (decision 0007); wraps AzooKeyKanaKanjiConverter + Zenzai for the
// actual conversion (decision 0001).
//
// STATUS: startup, the accept loop and request routing are wired together, but
// nothing has been exercised against a real TSF client yet.

import Foundation
import OhageyEngineCore

// NOTE: this file is `main.swift`, so it is top-level code and must not carry
// the `@main` attribute — Swift rejects the two together. The entry point is
// the `OhageyEngineMain.main()` call at the bottom of the file.
enum OhageyEngineMain {
    // `@MainActor` because it builds the ConversionService, which upstream pins
    // to the main actor. Top-level code is already main-actor isolated, so the
    // call at the bottom of the file needs no await.
    @MainActor
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

            let service = ConversionService(settings: settings)
            let router = RequestRouter(handler: service)

            // Settings arrive by file, not by IPC (decision 0014). Applied on
            // the main actor because that is where the converter lives; live
            // connections are untouched, and the new values take effect on the
            // next conversion.
            SettingsWatcher.start(
                settingsURL: EnginePaths.settingsURL,
                initial: settings,
                log: log
            ) { reloaded in
                Task { @MainActor in service.updateSettings(reloaded) }
            }

            let idleTimeout = settings.idleTimeoutSeconds
            let watchdog = IdleWatchdog(timeout: TimeInterval(idleTimeout)) {
                log("idle for \(idleTimeout)s with no client — exiting (decision 0015)")
                exit(0)
            }
            // Armed before the pipe exists: a client that launched us and then
            // died would otherwise leave this process resident forever.
            watchdog.start()

            // The accept loop blocks in ConnectNamedPipe, so it cannot share
            // the main thread with the converter's executor.
            let acceptThread = Thread {
                do {
                    try PipeServer.runAcceptLoop(
                        name: name,
                        router: router,
                        watchdog: watchdog,
                        log: log
                    )
                } catch {
                    // Reaching here means we could not create a pipe instance
                    // at all — no client will ever connect, so staying up would
                    // just look like a hung IME.
                    log("fatal: accept loop stopped: \(error)")
                    exit(1)
                }
            }
            acceptThread.name = "ohagey-accept"
            acceptThread.start()

            log("listening")
            // Hands the main thread to the main-actor executor and never
            // returns. Conversion is main-actor isolated, so without this the
            // connection threads would wait on work that nothing runs.
            dispatchMain()
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

    // `@Sendable` and a stored closure rather than a plain method: the accept
    // loop and every connection thread log, so this crosses threads.
    private static let log: @Sendable (String) -> Void = { message in
        // Console logging only. No telemetry, no crash reporting, nothing
        // leaves the machine (decision 0016).
        print("OhageyEngine: \(message)")
        // Flush every line. stdout is block-buffered once redirected to a file,
        // and this process usually ends by idle timeout or by being killed —
        // both of which discard the buffer, so a log kept for diagnosing a
        // problem would be empty exactly when it was needed. Log lines are
        // rare enough that the syscall does not matter.
        fflush(stdout)
    }
}

// Top-level code runs on the main thread but is not main-actor *isolated* in
// the Swift 5 language mode, so the compiler will not let it call a
// `@MainActor` method directly. `assumeIsolated` states what is already true
// here rather than hopping. (Once Package.swift moves to `.v6`, top-level code
// becomes main-actor isolated and this can go back to a plain call.)
MainActor.assumeIsolated { OhageyEngineMain.main() }

// TODO (implementation phase, tracked in docs/roadmap.md):
//  1. Settings hot-reload via file/registry watching (decision 0014).
//  2. User-dictionary storage, so registerWord stops returning an error
//     (decision 0026).
//  3. Backend selection via the DLL search path at startup (decision 0028).
