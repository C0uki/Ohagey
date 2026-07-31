// Reading settings out of HKCU (decision 0014).
//
// The Windows half of the schema. What the values mean — defaults, ranges,
// which ones exist — is in OhageyEngineCore/SettingsSchema.swift, where it can
// be tested without a registry.
//
// Values are enumerated rather than queried by name: one pass over the key
// hands the whole set to the core, which then decides what it recognises. A
// settings app that writes a value this build has never heard of costs nothing,
// and adding a setting later needs no change here.

import Foundation
#if os(Windows)
import WinSDK
#endif
import OhageyEngineCore

#if os(Windows)
enum RegistrySettings {
    /// Opens the settings key, creating it if it is not there.
    ///
    /// Creation matters for the watch, not the read: `RegNotifyChangeKeyValue`
    /// needs an open key, and a key that does not exist cannot be watched. On a
    /// fresh profile the engine would then never notice the settings app's
    /// first write — the user would change a setting, see nothing happen, and
    /// be right to conclude it was broken. Creating an empty key under the
    /// user's own HKCU costs nothing and is not the same as writing settings:
    /// the engine still never puts a value in it.
    /// KEY_READ | KEY_NOTIFY.
    ///
    /// Spelled out because Swift's WinSDK does not surface the composite
    /// access-mask macros — the same reason PipeSecurity writes its masks as
    /// numbers. KEY_READ is already STANDARD_RIGHTS_READ (0x20000) |
    /// KEY_QUERY_VALUE (0x1) | KEY_ENUMERATE_SUB_KEYS (0x8) | KEY_NOTIFY
    /// (0x10); the notify right is what the watcher needs and is included here.
    private static let readAccess: DWORD = 0x2_0019

    static func openKey(create: Bool) -> HKEY? {
        var key: HKEY?
        let path = SettingsSchema.registryPath

        let access = readAccess
        let status: LSTATUS = path.withCString(encodedAs: UTF16.self) { wide in
            if create {
                var disposition: DWORD = 0
                return RegCreateKeyExW(
                    HKEY_CURRENT_USER, wide, 0, nil,
                    DWORD(REG_OPTION_NON_VOLATILE), access, nil, &key, &disposition
                )
            }
            return RegOpenKeyExW(HKEY_CURRENT_USER, wide, 0, access, &key)
        }

        guard status == ERROR_SUCCESS else { return nil }
        return key
    }

    /// Every value under the settings key.
    ///
    /// An unreadable key yields an empty dictionary, which the core turns into
    /// defaults. That is the right answer for a fresh profile and the only
    /// tolerable one for a damaged key: an IME that refuses to convert because
    /// it could not read a preference is worse than one using defaults.
    static func read(key: HKEY) -> [String: SettingsValue] {
        var values: [String: SettingsValue] = [:]

        // Registry value names are capped at 16383 characters; data here is
        // a DWORD or a short string. Sized for the cap so a long name cannot
        // truncate into a different name.
        let nameCapacity = 16_384
        var index: DWORD = 0

        while true {
            var name = [WCHAR](repeating: 0, count: nameCapacity)
            var nameLength = DWORD(nameCapacity)
            var type: DWORD = 0
            var data = [UInt8](repeating: 0, count: 1024)
            var dataLength = DWORD(data.count)

            let status = RegEnumValueW(
                key, index, &name, &nameLength, nil, &type, &data, &dataLength
            )
            if status == ERROR_NO_MORE_ITEMS { break }
            index += 1
            guard status == ERROR_SUCCESS else {
                // One unreadable value should not hide the rest — a value too
                // large for the buffer above, for instance, is not a reason to
                // stop reading the ones after it.
                continue
            }

            let valueName = String(decodingCString: name, as: UTF16.self)
            guard !valueName.isEmpty else { continue }

            switch type {
            case DWORD(REG_DWORD):
                guard dataLength >= 4 else { continue }
                // Little-endian, assembled by hand rather than bound to a
                // UInt32: `data` is a [UInt8] whose alignment nothing promises.
                //
                // Read as a signed 32-bit value. The registry has no signed
                // type, but a settings app that writes -1 stores 0xFFFFFFFF,
                // and reading that as four billion would sail past every range
                // check in the schema.
                let raw = UInt32(data[0])
                    | UInt32(data[1]) << 8
                    | UInt32(data[2]) << 16
                    | UInt32(data[3]) << 24
                values[valueName] = .number(Int(Int32(bitPattern: raw)))

            case DWORD(REG_SZ), DWORD(REG_EXPAND_SZ):
                // Only the bytes the value actually occupies, and only whole
                // UTF-16 units. A string value is not required to be
                // NUL-terminated in the registry, so the length is the
                // authority rather than a terminator that may not be there.
                let units = Int(dataLength) / 2
                guard units > 0 else {
                    values[valueName] = .text("")
                    continue
                }
                var scalars = [UInt16](repeating: 0, count: units)
                for i in 0 ..< units {
                    scalars[i] = UInt16(data[i * 2]) | UInt16(data[i * 2 + 1]) << 8
                }
                // Trailing NULs, if the writer did include one.
                while let last = scalars.last, last == 0 { scalars.removeLast() }
                values[valueName] = .text(String(decoding: scalars, as: UTF16.self))

            default:
                // A type the schema does not use. Dropped here rather than
                // guessed at.
                continue
            }
        }

        return values
    }

    /// Current settings, or defaults if nothing readable is there.
    static func load() -> EngineSettings {
        guard let key = openKey(create: false) else { return .default }
        defer { RegCloseKey(key) }
        return EngineSettings(values: read(key: key))
    }
}
#endif
