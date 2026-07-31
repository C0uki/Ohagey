using System.Reflection;
using Microsoft.UI.Xaml.Controls;

namespace Ohagey.Settings.Pages;

public sealed partial class AboutPage : Page
{
    public AboutPage()
    {
        InitializeComponent();

        var version = Assembly.GetExecutingAssembly().GetName().Version;
        VersionText.Text = $"バージョン {version?.ToString(3) ?? "0.0.1"}";
    }
}
