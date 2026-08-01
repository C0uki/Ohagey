// Choosing which llama.cpp build the process loads (decision 0028).
//
// The layout and the fallback rule are in OhageyEngineCore/BackendLayout.swift;
// this is the Windows half.
//
// ── Why this has to run before the first conversion ─────────────────────────
//
// `llama.dll` is delay-loaded (see the linker settings in Package.swift), so
// the loader resolves it at the first call into llama rather than at process
// start. That first call happens inside the converter, on the first Zenzai
// conversion. Everything here must therefore be done before then — which in
// practice means at startup, before any client can connect.
//
// Without the delay load this file could not work at all: llama.dll would be
// an ordinary static import, bound before `main` runs.
//
// ── Why the backend is loaded here rather than left to the delay load ───────
//
// Pointing the search path at a directory only settles *which* llama.dll would
// be chosen, not whether it can be loaded. A CUDA build sitting next to no CUDA
// runtime is a file that exists and will not load. Left to the delay-load
// helper, that surfaces as a structured exception on the first conversion — the
// engine dies mid-sentence, and decision 0028's "fall back to CPU" never gets a
// chance to happen.
//
// So the DLL is loaded here, eagerly, while there is still somewhere to fall
// back to. This is a probe and a commitment at once: the delay-load helper
// later calls LoadLibrary by base name, and Windows resolves that against the
// already-loaded module list, so whatever is loaded here is what llama calls
// into. It is the same mechanism azooKey-Windows gets from putting the backend
// directory on PATH, made explicit and checkable.

import Foundation
#if os(Windows)
import WinSDK
#endif
import OhageyEngineCore

#if os(Windows)
enum BackendLoader {
    /// What happened when the backend was selected.
    struct Outcome {
        /// The backend whose DLLs the process loaded. Nil when none did.
        let backend: Backend?
        let reason: BackendSelectionReason
        /// Win32 error code, when a load failed.
        let detail: String?
        let directory: URL?

        var isRequested: Bool { reason == .requested }
    }

    /// Loads the chosen backend, falling back to CPU when it will not load.
    ///
    /// Never fails outright: when nothing loads, the process is left with a
    /// delay-load that will fail on the first conversion, and the caller reports
    /// that and carries on. Dictionary-only conversion still works, exactly as
    /// when the model is missing (decision 0008).
    static func select(_ requested: Backend, log: (String) -> Void) -> Outcome {
        guard let executable = executableURL() else {
            log("backend: cannot determine the engine's own path; leaving the DLL search path alone")
            return Outcome(backend: nil, reason: .unavailable, detail: nil, directory: nil)
        }

        // Switches the process to the restricted search order, which is what
        // makes AddDllDirectory take effect at all. It also drops the current
        // directory and %PATH% from the search — a good thing here beyond the
        // mechanics: the engine is started by whichever application the user
        // happened to be typing in (decision 0033), and inheriting that
        // application's PATH is not a sound way to decide which llama.dll to
        // load.
        //
        // LOAD_LIBRARY_SEARCH_DEFAULT_DIRS = 0x1000. Spelled as a number
        // because Swift's WinSDK does not surface these flag macros — the same
        // reason PipeSecurity writes its access masks out.
        guard SetDefaultDllDirectories(0x0000_1000) else {
            log("backend: SetDefaultDllDirectories failed (\(GetLastError())); leaving the DLL search path alone")
            return Outcome(backend: nil, reason: .unavailable, detail: String(GetLastError()), directory: nil)
        }

        var candidates = [requested]
        if requested != BackendLayout.fallback { candidates.append(BackendLayout.fallback) }

        // Why the requested backend failed, kept from the first attempt. Later
        // attempts are the fallback, and the user needs to know what went wrong
        // with the one they picked, not with the one that rescued them.
        var reason = BackendSelectionReason.unavailable
        var detail: String?

        for (index, backend) in candidates.enumerated() {
            let isRequested = index == 0
            let directory = BackendLayout.directory(for: backend, besideExecutableAt: executable)
            let library = directory.appendingPathComponent(BackendLayout.probeLibrary)

            guard FileManager.default.fileExists(atPath: library.path) else {
                if isRequested {
                    reason = .notInstalled
                    log("backend: \(backend.rawValue) is not installed (no \(BackendLayout.probeLibrary) under \(directory.path))")
                }
                continue
            }

            guard let cookie = addToSearchPath(directory) else {
                if isRequested {
                    reason = .loadFailed
                    detail = String(GetLastError())
                    log("backend: could not add \(directory.path) to the DLL search path (\(GetLastError()))")
                }
                continue
            }

            if load(library) {
                if isRequested {
                    log("backend: \(backend.rawValue) from \(directory.path)")
                    return Outcome(backend: backend, reason: .requested, detail: nil, directory: directory)
                }
                // Said plainly. The settings app shows the requested backend,
                // and a user who selected CUDA and silently got CPU would have
                // no way to tell why conversion felt slow.
                log("backend: fell back to \(backend.rawValue) from \(directory.path)")
                return Outcome(backend: backend, reason: reason, detail: detail, directory: directory)
            }

            let error = GetLastError()
            // Taken back out of the search path. It holds a llama.dll that will
            // not load, and leaving it there would let its ggml*.dll be found
            // ahead of the ones belonging to the backend that does work.
            RemoveDllDirectory(cookie)
            log("backend: \(backend.rawValue) is installed but would not load (\(error))"
                + (error == 126 ? " — a DLL it depends on is missing" : ""))
            if isRequested {
                reason = .loadFailed
                detail = String(error)
            }
        }

        log("backend: no usable backend under \(BackendLayout.directoryName)\\ — Zenzai will be unavailable")
        return Outcome(backend: nil, reason: .unavailable, detail: detail, directory: nil)
    }

    /// Adds a directory to the process's DLL search path, returning its cookie.
    private static func addToSearchPath(_ directory: URL) -> DLL_DIRECTORY_COOKIE? {
        directory.path.withCString(encodedAs: UTF16.self) { path in
            AddDllDirectory(path)
        }
    }

    /// Loads a DLL by full path, resolving its dependencies from the same
    /// directory and the ones already added.
    ///
    /// `LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR` (0x100) is what makes a CUDA build
    /// find its own `ggml-cuda.dll` and vendor runtime; without it the loader
    /// would look beside the *executable* instead, which is where a different
    /// backend's DLLs are. `LOAD_LIBRARY_SEARCH_DEFAULT_DIRS` (0x1000) keeps
    /// the system directory available for the OS libraries llama links.
    private static func load(_ library: URL) -> Bool {
        library.path.withCString(encodedAs: UTF16.self) { path in
            LoadLibraryExW(path, nil, 0x0000_0100 | 0x0000_1000) != nil
        }
    }

    private static func executableURL() -> URL? {
        var buffer = [WCHAR](repeating: 0, count: Int(MAX_PATH) + 1)
        let written = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        guard written > 0, written < buffer.count else { return nil }
        return URL(fileURLWithPath: String(decodingCString: buffer, as: UTF16.self))
    }
}
#endif
