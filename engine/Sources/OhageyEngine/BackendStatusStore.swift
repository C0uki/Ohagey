// Writing the backend status file (decision 0028).
//
// The record and its format are in OhageyEngineCore/BackendStatus.swift; this
// is the part that touches the disk.

import Foundation
import OhageyEngineCore

enum BackendStatusStore {
    /// Records the selection, ignoring any failure to do so.
    ///
    /// Best effort on purpose. This file exists so the settings app can explain
    /// something to the user; not being able to write it is worth a log line and
    /// nothing more. An IME that refuses to start because a diagnostic file is
    /// unwritable has its priorities backwards.
    static func write(_ status: BackendStatus, log: (String) -> Void) {
        do {
            try EnginePaths.ensureUserDataDirectoryExists()
            try BackendStatusFile.serialize(status)
                .write(to: BackendStatusFile.url, atomically: true, encoding: .utf8)
        } catch {
            log("backend: could not record the status file (\(error))")
        }
    }
}
