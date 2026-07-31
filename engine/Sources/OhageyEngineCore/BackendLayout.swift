// Where each inference backend's DLLs live (decision 0028).
//
// Zenzai runs on llama.cpp, and which backend it uses is decided by *which
// llama.dll the process loads* — there is no runtime switch inside the library.
// So the choice is made by the DLL search path, and the install ships one
// directory per backend beside the engine (decision 0033):
//
//     %ProgramFiles%\Ohagey\
//         OhageyEngine.exe
//         backends\
//             cpu\     llama.dll ggml*.dll
//             cuda\    ...
//             vulkan\  ...
//
// ── Why the engine cannot simply call SetDllDirectory ───────────────────────
//
// `llama.dll` is a *static* import of the engine executable, which the Windows
// loader resolves before a single line of Ohagey's code runs. Anything main()
// does about search paths is far too late. Confirmed with dumpbin: llama.dll
// sits in the ordinary import table, not the delay-load one.
//
// The fix is to delay-load it (see Package.swift), which moves the resolution
// to the first call into llama — by which time the engine has had a chance to
// say where to look.
//
// This file is the part of that with no Windows in it: which directory belongs
// to which backend, and what to fall back to.

import Foundation

public enum BackendLayout {
    /// Subdirectory holding one directory per backend.
    public static let directoryName = "backends"

    /// Backend to use when the chosen one cannot be loaded.
    ///
    /// CPU, because it is the one that always works: it needs no driver, no
    /// device and no vendor runtime. An IME that will not convert is worse
    /// than one converting slowly (decision 0028).
    public static let fallback = Backend.cpu

    /// Directory name for a backend. Lowercase, matching the settings value.
    public static func directoryName(for backend: Backend) -> String {
        backend.rawValue
    }

    /// Where a backend's DLLs live, given the directory holding the engine.
    public static func directory(for backend: Backend, besideExecutableAt executable: URL) -> URL {
        executable
            .deletingLastPathComponent()
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(directoryName(for: backend), isDirectory: true)
    }

    /// The DLL whose presence means a backend is actually installed.
    ///
    /// Only llama.dll is checked. Its own dependencies (`ggml*.dll` and, for
    /// CUDA, the vendor runtime) sit beside it and are resolved by the same
    /// search path; listing them here would be a second copy of llama.cpp's
    /// build layout, and one that goes stale.
    public static let probeLibrary = "llama.dll"

    /// Whether a backend looks usable.
    ///
    /// `contains` is injected so the decision can be tested without a
    /// filesystem; the caller supplies a real existence check.
    public static func isAvailable(
        _ backend: Backend,
        besideExecutableAt executable: URL,
        contains: (URL) -> Bool
    ) -> Bool {
        contains(directory(for: backend, besideExecutableAt: executable)
            .appendingPathComponent(probeLibrary))
    }

    /// The backend to actually load, and whether that is what was asked for.
    ///
    /// Returns nil when even the fallback is missing — which is not a
    /// recoverable state, but is worth reporting as itself rather than as a
    /// mysterious failure to convert.
    public static func resolve(
        requested: Backend,
        besideExecutableAt executable: URL,
        contains: (URL) -> Bool
    ) -> (backend: Backend, isRequested: Bool)? {
        if isAvailable(requested, besideExecutableAt: executable, contains: contains) {
            return (requested, true)
        }
        if requested != fallback,
           isAvailable(fallback, besideExecutableAt: executable, contains: contains) {
            return (fallback, false)
        }
        return nil
    }
}
