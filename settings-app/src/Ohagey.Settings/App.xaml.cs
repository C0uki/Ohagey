using Microsoft.UI.Xaml;

namespace Ohagey.Settings;

public partial class App : Application
{
    /// <summary>The one window, for anything that needs an HWND.</summary>
    /// <remarks>
    /// Exposed because an unpackaged WinUI 3 app has to parent its file pickers
    /// to a window handle explicitly (WinRT.Interop.InitializeWithWindow) —
    /// without one, FileOpenPicker throws at runtime with nothing at compile
    /// time to warn about it. There is exactly one window, so this is a fact
    /// rather than a lookup.
    /// </remarks>
    internal static Window? MainWindow { get; private set; }

    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        MainWindow = new MainWindow();
        MainWindow.Activate();
    }
}
