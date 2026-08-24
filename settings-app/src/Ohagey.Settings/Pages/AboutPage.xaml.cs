using System.Reflection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Ohagey.Settings.Core;

namespace Ohagey.Settings.Pages;

public sealed partial class AboutPage : Page
{
    private readonly ISettingsStore _store = new RegistrySettingsStore();

    /// <summary>Set while the switch is being populated, so loading is not a change.</summary>
    private bool _loading;

    public AboutPage()
    {
        InitializeComponent();

        var version = Assembly.GetExecutingAssembly().GetName().Version;
        VersionText.Text = $"バージョン {version?.ToString(3) ?? "0.0.1"}";

        LoadDiagnostics();
    }

    private void LoadDiagnostics()
    {
        _loading = true;
        DiagnosticLogSwitch.IsOn = _store.Read().DiagnosticLog;
        _loading = false;

        RefreshDiagnostics();
    }

    /// <summary>
    /// Shows where the log is and whether the restart notice applies.
    /// </summary>
    /// <remarks>
    /// The notice is raised only while the switch is on. Turning it off also
    /// reaches applications only when they restart, but the consequence of not
    /// knowing that is a log that keeps growing for a while — not the "I turned
    /// it on and nothing happened" that sends someone looking for a bug.
    /// </remarks>
    private void RefreshDiagnostics()
    {
        DiagnosticLogPath.Text = Diagnostics.Describe();
        DiagnosticLogNotice.IsOpen = DiagnosticLogSwitch.IsOn;
        DeleteLogButton.IsEnabled = Diagnostics.LogExists;
    }

    private void OnDiagnosticLogToggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;

        // Read back before writing, so this page does not overwrite settings
        // the learning or backend pages changed while it was open. Every page
        // writes the whole record.
        _store.Write(_store.Read() with { DiagnosticLog = DiagnosticLogSwitch.IsOn });
        RefreshDiagnostics();
    }

    private void OnDeleteLogClicked(object sender, RoutedEventArgs e)
    {
        // Not reported as done when it is not. The DLL is loaded into every
        // application with a text input surface, so one of them can be holding
        // the file open, and saying "deleted" over a file that is still there
        // is the wrong answer on a button someone pressed for privacy.
        var deleted = Diagnostics.DeleteLog();
        if (!deleted)
        {
            DiagnosticLogPath.Text =
                "ログを削除できませんでした。使用中のアプリがある可能性があります。"
                + $"\n{Diagnostics.LogPath}";
            return;
        }

        RefreshDiagnostics();
    }
}
