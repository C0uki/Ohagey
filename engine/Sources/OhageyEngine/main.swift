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
        // First line of every session, and the reason the log carries a pid:
        // several processes start and exit over a day (decision 0015) and all
        // of them append here. Naming the binary answers "which build is
        // actually running", which was unanswerable from inside the machine
        // when the installer turned out to be re-registering an old DLL
        // (decision 0033).
        log("starting: \(CommandLine.arguments.first ?? "unknown path")")

        do {
            try EnginePaths.ensureUserDataDirectoryExists()
        } catch {
            // Without this directory learning and the user dictionary cannot be
            // persisted, but conversion itself still works — keep going.
            log("could not create \(EnginePaths.userDataDirectory.path): \(error)")
        }

        // Settings come from HKCU (decision 0014). Off Windows there is no
        // registry to read and the engine is only being type-checked, so the
        // defaults stand in.
        #if os(Windows)
        let settings = RegistrySettings.load()
        #else
        let settings = EngineSettings.default
        #endif
        log("settings loaded (learning=\(settings.learningEnabled), backend=\(settings.backend.rawValue))")

        // Called out separately rather than left to be inferred from the path
        // below: a stray OHAGEY_MODEL_PATH in someone's environment should be
        // obvious, not something they have to notice.
        if EnginePaths.honorsModelPathOverride,
           ProcessInfo.processInfo.environment[EnginePaths.modelPathOverrideVariable] != nil {
            log("\(EnginePaths.modelPathOverrideVariable) is set — debug builds only, ignored in release")
        }
        log(EnginePaths.isModelAvailable
            ? "Zenzai model found at \(EnginePaths.modelURL.path)"
            // Not an error: the install is allowed to complete without the
            // model, and conversion degrades to the dictionary path (0008).
            : "Zenzai model missing — falling back to dictionary-only conversion")

        #if os(Windows)
        // Before anything can call into llama: the DLL is delay-loaded, and
        // this decides which backend's copy that resolves to (decision 0028).
        // Doing it after a client could connect would be a race with the first
        // conversion.
        let selected = BackendLoader.select(settings.backend, log: log)

        // Recorded for the settings app, which almost never has an engine
        // running to ask (decisions 0015 / 0028). Best effort: failing to write
        // it costs a diagnostic, and refusing to start an IME over that would
        // be the wrong trade.
        BackendStatusStore.write(
            BackendStatus(
                requested: settings.backend,
                effective: selected.backend,
                reason: selected.reason,
                detail: selected.detail
            ),
            log: log
        )

        do {
            let sessionId = try PipeServer.currentSessionId()
            let name = PipeServer.pipeName(sessionId: sessionId)
            log("pipe name: \(name)")

            // The effective backend, not the requested one: if CUDA was asked
            // for and is not installed, `ping` has to say cpu or the settings
            // app will show something the engine is not doing.
            let service = ConversionService(
                settings: settings,
                effectiveBackend: selected.backend ?? settings.backend,
                log: log
            )
            let router = RequestRouter(handler: service, log: log)

            // Settings arrive through the registry, not by IPC (decision 0014).
            // Applied on the main actor because that is where the converter
            // lives; live connections are untouched, and the new values take
            // effect on the next conversion.
            SettingsWatcher.start(
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

    // Opened lazily, on the first line: an engine started only to be told the
    // pipe is already taken should not leave a file behind.
    private static let logFile = EngineLogFile(
        url: EnginePaths.logURL,
        // Not TimeZone.current: it is GMT here. See LocalTimeZone.
        timeZone: LocalTimeZone.current
    )

    // `@Sendable` and a stored closure rather than a plain method: the accept
    // loop and every connection thread log, so this crosses threads.
    private static let log: @Sendable (String) -> Void = { message in
        // Console and a local file. No telemetry, no crash reporting, nothing
        // leaves the machine (decision 0016).
        //
        // The console half is for developers running the engine by hand. In
        // the shipped arrangement the engine is started by a TSF DLL inside
        // the application being typed in, which has no console at all — so
        // without the file, a real session says nothing about itself. Never
        // put what the user typed in here; see EngineLogFile.
        logFile.append(message)
        print("OhageyEngine: \(message)")
        // Flush every line. stdout is block-buffered once redirected to a file,
        // and this process usually ends by idle timeout or by being killed —
        // both of which discard the buffer, so a log kept for diagnosing a
        // problem would be empty exactly when it was needed. Log lines are
        // rare enough that the syscall does not matter.
        fflush(stdout)
    }
}

// Top-level code is main-actor isolated in the Swift 6 language mode, which
// the package now uses throughout, so this is a plain call. It was
// `MainActor.assumeIsolated { ... }` under `.v5`, where top-level code runs on
// the main thread without being *isolated* to it and the compiler therefore
// refused a direct call to a `@MainActor` method.
OhageyEngineMain.main()
