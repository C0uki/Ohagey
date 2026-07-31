using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Ohagey.Settings.Pages;

namespace Ohagey.Settings;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Title = "おはぎー 設定";
        Navigation.SelectedItem = Navigation.MenuItems[0];
    }

    private void OnSectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is not NavigationViewItem item) return;

        ContentFrame.Navigate(item.Tag switch
        {
            "learning" => typeof(LearningPage),
            "dictionary" => typeof(DictionaryPage),
            "about" => typeof(AboutPage),
            _ => typeof(BackendPage),
        });
    }
}
