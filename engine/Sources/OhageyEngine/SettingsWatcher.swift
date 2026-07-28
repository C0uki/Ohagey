// Settings hot-reload (decision 0014).
//
// Settings arrive by the settings app writing a file, not by an IPC push, so
// the engine has to notice on its own. This watches the containing directory
// with ReadDirectoryChangesW and re-reads settings.json when it is touched.
//
// It watches the *directory* because that is the only thing Windows will watch:
// there is no per-file notification, and a file handle would not survive the
// write-temp-then-rename dance that atomic savers do. The directory also holds
// learning data, which changes constantly, so events are filtered by name.
//
// Blocking, on its own thread, for the same reason as the pipe threads — see
// the concurrency note in PipeServer.swift.

import Foundation
#if os(Windows)
import WinSDK
#endif
import OhageyEngineCore

#if os(Windows)
enum SettingsWatcher {
    /// Big enough that a burst of writes to the data directory does not
    /// overflow it in one wait. Overflow is survivable — see the handling of a
    /// zero-length result below — but it costs a full re-read.
    private static let bufferSize = 16 * 1024

    /// Starts watching on a background thread. Never returns to the caller;
    /// the thread runs for the life of the process.
    ///
    /// `onChange` is called only when the file both parses *and* differs from
    /// what was last applied, so a save that changes nothing is silent, and a
    /// half-written file is ignored until the writer finishes.
    static func start(
        settingsURL: URL,
        initial: EngineSettings,
        log: @escaping @Sendable (String) -> Void,
        onChange: @escaping @Sendable (EngineSettings) -> Void
    ) {
        let directory = settingsURL.deletingLastPathComponent()
        let fileName = settingsURL.lastPathComponent

        let thread = Thread {
            run(
                directory: directory,
                fileName: fileName,
                settingsURL: settingsURL,
                initial: initial,
                log: log,
                onChange: onChange
            )
        }
        thread.name = "ohagey-settings-watcher"
        thread.start()
    }

    private static func run(
        directory: URL,
        fileName: String,
        settingsURL: URL,
        initial: EngineSettings,
        log: @escaping @Sendable (String) -> Void,
        onChange: @escaping @Sendable (EngineSettings) -> Void
    ) {
        guard let handle = openDirectory(directory) else {
            // Not fatal: the engine runs fine on whatever settings it started
            // with, it just will not notice edits.
            log("settings hot-reload unavailable: cannot watch \(directory.path) (\(GetLastError()))")
            return
        }
        defer { _ = CloseHandle(handle) }

        // FILE_LIST_DIRECTORY requires the buffer to be DWORD-aligned, and
        // FILE_NOTIFY_INFORMATION is read through a struct pointer — an
        // unaligned buffer would be undefined behaviour, not merely slow.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var applied = initial
        log("watching \(settingsURL.path) for changes")

        while true {
            var bytesReturned: DWORD = 0
            let ok = ReadDirectoryChangesW(
                handle,
                buffer,
                DWORD(bufferSize),
                false,  // this directory only; learning data lives here too but flat
                DWORD(FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_FILE_NAME),
                &bytesReturned,
                nil,
                nil
            )
            guard ok else {
                log("settings watch stopped: ReadDirectoryChangesW failed (\(GetLastError()))")
                return
            }

            // Zero means the buffer overflowed and the change list was
            // discarded. We do not know what changed, so assume it was ours.
            let touched = bytesReturned == 0
                || changedNames(in: buffer, byteCount: Int(bytesReturned))
                    .contains { $0.caseInsensitiveCompare(fileName) == .orderedSame }
            guard touched else { continue }

            guard let reloaded = try? EngineSettings.decode(from: settingsURL) else {
                // Almost always a file caught mid-write; the writer's final
                // notification will bring us back here. Deliberately not
                // logged: a noisy log during every save teaches people to
                // ignore it.
                continue
            }
            guard reloaded != applied else { continue }

            let needsRestart = reloaded.settingsRequiringRestart(comparedTo: applied)
            if !needsRestart.isEmpty {
                log("settings changed; a restart is needed for: \(needsRestart.joined(separator: ", "))")
            }
            applied = reloaded
            log("settings reloaded (learning=\(reloaded.learningEnabled))")
            onChange(reloaded)
        }
    }

    private static func openDirectory(_ directory: URL) -> HANDLE? {
        let handle = directory.path.withCString(encodedAs: UTF16.self) { path in
            CreateFileW(
                path,
                DWORD(FILE_LIST_DIRECTORY),
                // Sharing everything: the settings app must stay free to write
                // and replace files here while we hold the directory open.
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_FLAG_BACKUP_SEMANTICS),  // required to open a directory
                nil
            )
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
        return handle
    }

    /// Walks the FILE_NOTIFY_INFORMATION chain the kernel wrote into `buffer`.
    private static func changedNames(in buffer: UnsafeMutableRawPointer, byteCount: Int) -> [String] {
        var names: [String] = []
        var offset = 0

        while offset + MemoryLayout<FILE_NOTIFY_INFORMATION>.size <= byteCount {
            let record = buffer.advanced(by: offset)
                .assumingMemoryBound(to: FILE_NOTIFY_INFORMATION.self).pointee

            // FileNameLength is in bytes, and the name is not null-terminated.
            let nameByteCount = Int(record.FileNameLength)
            let nameOffset = offset + MemoryLayout<FILE_NOTIFY_INFORMATION>.offset(of: \.FileName)!
            if nameByteCount > 0, nameOffset + nameByteCount <= byteCount {
                let units = UnsafeRawBufferPointer(
                    start: buffer.advanced(by: nameOffset),
                    count: nameByteCount
                ).bindMemory(to: UInt16.self)
                names.append(String(decoding: units, as: UTF16.self))
            }

            // A zero NextEntryOffset marks the last record; without this check
            // a malformed chain would loop forever.
            guard record.NextEntryOffset != 0 else { break }
            offset += Int(record.NextEntryOffset)
        }
        return names
    }
}
#endif
