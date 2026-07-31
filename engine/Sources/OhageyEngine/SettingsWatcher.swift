// Settings hot-reload (decision 0014).
//
// Settings arrive by the settings app writing to HKCU, not by an IPC push, so
// the engine has to notice on its own. This waits on the settings key with
// RegNotifyChangeKeyValue and re-reads it when anything under it is set.
//
// The notification says only "something changed" — not which value, and not
// what it became — so every wake-up re-reads the whole key. That is a handful
// of registry values and happens when a human clicks something, so the cost is
// irrelevant and the alternative (tracking per-value state) buys nothing.
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
    /// Starts watching on a background thread. Never returns to the caller;
    /// the thread runs for the life of the process.
    ///
    /// `onChange` is called only when the settings actually differ from what
    /// was last applied, so a save that changes nothing is silent.
    static func start(
        initial: EngineSettings,
        log: @escaping @Sendable (String) -> Void,
        onChange: @escaping @Sendable (EngineSettings) -> Void
    ) {
        let thread = Thread {
            run(initial: initial, log: log, onChange: onChange)
        }
        thread.name = "ohagey-settings-watcher"
        thread.start()
    }

    private static func run(
        initial: EngineSettings,
        log: @escaping @Sendable (String) -> Void,
        onChange: @escaping @Sendable (EngineSettings) -> Void
    ) {
        // Created if absent: a key that does not exist cannot be watched, and
        // on a fresh profile that would mean never noticing the settings app's
        // very first write. See RegistrySettings.openKey.
        guard let key = RegistrySettings.openKey(create: true) else {
            // Not fatal: the engine runs fine on whatever settings it started
            // with, it just will not notice edits.
            log("settings hot-reload unavailable: cannot open HKCU\\\(SettingsSchema.registryPath) (\(GetLastError()))")
            return
        }
        defer { RegCloseKey(key) }

        // Manual reset, so a change arriving between the wait returning and the
        // next registration is not lost: the event stays signalled and the next
        // wait returns at once. Auto-reset would drop it.
        guard let event = CreateEventW(nil, true, false, nil) else {
            log("settings hot-reload unavailable: CreateEvent failed (\(GetLastError()))")
            return
        }
        defer { _ = CloseHandle(event) }

        var applied = initial
        log("watching HKCU\\\(SettingsSchema.registryPath) for changes")

        while true {
            // Re-registered every time round: a notification is one-shot, so
            // this has to be re-armed after each wake-up. Registered *before*
            // the read below, so a write landing between the two is caught by
            // the next wait rather than missed.
            _ = ResetEvent(event)
            let status = RegNotifyChangeKeyValue(
                key,
                true,  // subtree: leaves room for grouping settings under subkeys
                DWORD(REG_NOTIFY_CHANGE_LAST_SET | REG_NOTIFY_CHANGE_NAME),
                event,
                true   // asynchronous: signal the event rather than blocking here
            )
            guard status == ERROR_SUCCESS else {
                log("settings watch stopped: RegNotifyChangeKeyValue failed (\(status))")
                return
            }

            guard WaitForSingleObject(event, INFINITE) == WAIT_OBJECT_0 else {
                log("settings watch stopped: wait failed (\(GetLastError()))")
                return
            }

            let reloaded = EngineSettings(values: RegistrySettings.read(key: key))
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
}
#endif
