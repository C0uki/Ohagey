// The machine's time zone, asked of Windows rather than of Foundation
// (decision 0033).
//
// `TimeZone.current` on Swift for Windows returns GMT: Foundation there cannot
// read the system zone. Measured on a JST machine — identifier `GMT`,
// `secondsFromGMT()` 0 — while `TimeZone(identifier: "Asia/Tokyo")` formats
// correctly, so the zone database is present and only the lookup of the
// *current* zone is missing.
//
// Left alone, `engine.log` timestamps were nine hours off with no zone printed,
// which is worse than having no timestamps: the first real session was read as
// having happened at 08:00 when the user typed at 17:00.
//
// This lives in the executable target rather than in OhageyEngineCore because
// the core is deliberately free of WinSDK (see CLAUDE.md); the core takes a
// `TimeZone` and this is what supplies it.

import Foundation

#if os(Windows)
import WinSDK
#endif

enum LocalTimeZone {
    /// The current UTC offset, or GMT if Windows will not say.
    static var current: TimeZone {
        #if os(Windows)
        var info = TIME_ZONE_INFORMATION()
        let kind = GetTimeZoneInformation(&info)

        // Bias is in minutes to *add to local time to get UTC*, so the sign is
        // the opposite of what TimeZone wants. The seasonal part is separate
        // and only applies in the season being reported.
        let seasonal: LONG
        switch Int32(kind) {
        case Int32(TIME_ZONE_ID_DAYLIGHT): seasonal = info.DaylightBias
        case Int32(TIME_ZONE_ID_STANDARD): seasonal = info.StandardBias
        case Int32(TIME_ZONE_ID_UNKNOWN): seasonal = 0
        default:
            // TIME_ZONE_ID_INVALID. Nothing to do but keep the log honest by
            // leaving the timestamps in GMT rather than inventing an offset.
            return TimeZone(secondsFromGMT: 0) ?? .gmt
        }

        let minutes = info.Bias + seasonal
        return TimeZone(secondsFromGMT: -Int(minutes) * 60) ?? .gmt
        #else
        return .current
        #endif
    }
}
