// The text service's diagnostic log (decision 0033, addendum 19).
//
// Three components have to agree on one path and one registry value:
// OhageyTSF.dll writes the file, this app offers the switch, and
// SettingsSchema.swift carries the value name so nobody reuses it. Only the
// path lives here — the value name is in SettingsSchema.cs with the rest of the
// registry contract.
//
// The file itself is never parsed. This app shows where it is and how big it
// is, and deletes it on request; a user chasing a problem opens it themselves
// or sends it on.

namespace Ohagey.Settings.Core;

public static class Diagnostics
{
    /// <summary>
    /// Where OhageyTSF.dll writes its log.
    /// </summary>
    /// <remarks>
    /// Under the per-user data directory rather than beside the DLL: the DLL
    /// is in Program Files and runs inside applications that have no write
    /// access there. Built from <see cref="LearningData.DataDirectory"/> so the
    /// two cannot drift, even though this is not learning data.
    /// </remarks>
    public static string LogPath => Path.Combine(LearningData.DataDirectory, "tsf.log");

    public static bool LogExists => File.Exists(LogPath);

    /// <summary>Size of the log, or zero when there is none.</summary>
    public static long LogSizeBytes
    {
        get
        {
            try { return LogExists ? new FileInfo(LogPath).Length : 0; }
            catch (Exception) { return 0; }
        }
    }

    /// <summary>What to show the user under the switch.</summary>
    /// <remarks>
    /// The path is shown whether or not the file exists. Someone who has just
    /// switched this on needs to know where to look before there is anything
    /// to look at, and someone who switched it on and sees nothing needs the
    /// path to confirm they are looking in the right place.
    ///
    /// The size matters because the DLL caps the file at 1 MiB and then starts
    /// it again rather than rotating. A log sitting at the cap has lost its
    /// beginning, and a reader should know that before concluding an event is
    /// missing.
    /// </remarks>
    public static string Describe()
    {
        if (!LogExists)
        {
            return $"まだ記録はありません。記録先: {LogPath}";
        }

        var size = LogSizeBytes;
        var readable = size >= 1024 * 1024
            ? $"{size / 1024.0 / 1024.0:0.#} MB"
            : $"{size / 1024} KB";
        return $"記録先: {LogPath}({readable})";
    }

    /// <summary>Deletes the log, reporting whether it is gone.</summary>
    /// <remarks>
    /// True when there is no file afterwards, which includes there having been
    /// none to start with. False means something still holds it — every
    /// application with a text input surface has the DLL loaded, and one of
    /// them may be mid-write.
    /// </remarks>
    public static bool DeleteLog()
    {
        try
        {
            if (LogExists) File.Delete(LogPath);
            return !LogExists;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
