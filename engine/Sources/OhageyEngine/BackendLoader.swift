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

import Foundation
#if os(Windows)
import WinSDK
#endif
import OhageyEngineCore

#if os(Windows)
enum BackendLoader {
    /// What happened when the backend was selected.
    struct Outcome {
        /// The backend whose DLLs the process will load.
        let backend: Backend
        /// False when the requested one was unavailable and CPU stood in.
        let isRequested: Bool
        let directory: URL
    }

    /// Points the loader at the chosen backend's directory.
    ///
    /// Returns nil when no backend is installed at all, which leaves the
    /// process with a delay-load that will fail on the first conversion. The
    /// caller reports that and carries on: dictionary-only conversion still
    /// works, exactly as when the model is missing (decision 0008).
    static func select(_ requested: Backend, log: (String) -> Void) -> Outcome? {
        guard let executable = executableURL() else {
            log("backend: cannot determine the engine's own path; leaving the DLL search path alone")
            return nil
        }

        let fileManager = FileManager.default
        guard let resolved = BackendLayout.resolve(
            requested: requested,
            besideExecutableAt: executable,
            contains: { fileManager.fileExists(atPath: $0.path) }
        ) else {
            log("backend: no usable backend found under \(BackendLayout.directoryName)\\ — Zenzai will be unavailable")
            return nil
        }

        if !resolved.isRequested {
            // Said plainly. The settings app shows the requested backend, and a
            // user who selected CUDA and silently got CPU would have no way to
            // tell why conversion felt slow.
            log("backend: \(requested.rawValue) is not installed; falling back to \(resolved.backend.rawValue)")
        }

        let directory = BackendLayout.directory(for: resolved.backend, besideExecutableAt: executable)
        guard addToSearchPath(directory) else {
            log("backend: could not add \(directory.path) to the DLL search path (\(GetLastError()))")
            return nil
        }

        log("backend: \(resolved.backend.rawValue) from \(directory.path)")
        return Outcome(backend: resolved.backend, isRequested: resolved.isRequested, directory: directory)
    }

    /// Adds a directory to the process's DLL search path.
    private static func addToSearchPath(_ directory: URL) -> Bool {
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
        guard SetDefaultDllDirectories(0x0000_1000) else { return false }

        return directory.path.withCString(encodedAs: UTF16.self) { path in
            AddDllDirectory(path) != nil
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
