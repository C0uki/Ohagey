using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Ohagey.Settings.Core;

namespace Ohagey.Settings.Pages;

public sealed partial class LearningPage : Page
{
    private readonly ISettingsStore _store = new RegistrySettingsStore();
    private bool _loading;

    public LearningPage()
    {
        InitializeComponent();
        Load();
    }

    private void Load()
    {
        _loading = true;
        var settings = _store.Read();
        LearningSwitch.IsOn = settings.LearningEnabled;
        PersonalizationSwitch.IsOn = settings.PersonalizationEnabled;
        AlphaSlider.Value = settings.PersonalizationAlphaPercent;
        _loading = false;

        ApplyDependency(settings);
        RefreshEraseSummary();
    }

    /// <summary>
    /// Personalisation keeps a plain-text record of committed phrases, so it
    /// cannot outlive the consent that learning stands for (decision 0025).
    /// The engine enforces this too; showing it here keeps the UI from
    /// offering a combination that will not happen.
    /// </summary>
    private void ApplyDependency(EngineSettings settings)
    {
        PersonalizationSwitch.IsEnabled = settings.LearningEnabled;
        AlphaSlider.IsEnabled = settings.PersonalizationActive;
        PersonalizationNote.Text = settings.LearningEnabled
            ? "確定した語句を控えて学習し直します。切ると、その控えも消えます。"
            : "学習がオフのあいだは使えません。";
    }

    private void OnToggled(object sender, RoutedEventArgs e) => Save();

    private void OnSliderChanged(object sender, RangeBaseValueChangedEventArgs e) => Save();

    private void Save()
    {
        if (_loading) return;

        var updated = _store.Read() with
        {
            LearningEnabled = LearningSwitch.IsOn,
            PersonalizationEnabled = PersonalizationSwitch.IsOn,
            PersonalizationAlphaPercent = (int)AlphaSlider.Value,
        };

        _store.Write(updated);
        ApplyDependency(updated);
    }

    private void RefreshEraseSummary()
    {
        var bytes = LearningData.EstimateBytes();
        // Shown before the button is pressed. Erase is not undoable, and a
        // number is the cheapest way to say whether this is a session's worth
        // of typing or a year's.
        EraseSummary.Text = bytes == 0
            ? "消去できる学習データはありません。"
            : $"現在の学習データ: 約 {bytes / 1024} KB。"
              + "登録したユーザー辞書は消えません。";
        EraseButton.IsEnabled = bytes > 0;
    }

    private async void OnEraseClicked(object sender, RoutedEventArgs e)
    {
        var confirm = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "学習データを消去しますか?",
            Content = "これまでに覚えた変換の傾向がすべて消えます。元に戻せません。\n"
                      + "ユーザー辞書に登録した単語は消えません。",
            PrimaryButtonText = "消去する",
            CloseButtonText = "やめる",
            DefaultButton = ContentDialogButton.Close,
        };

        if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;

        var result = LearningData.Erase();
        EraseResultBar.IsOpen = true;
        if (result.Complete)
        {
            EraseResultBar.Severity = InfoBarSeverity.Success;
            EraseResultBar.Title = "消去しました";
            EraseResultBar.Message = $"{result.Removed.Count} 件を削除しました。";
        }
        else
        {
            // Not reported as success. The usual cause is the engine holding
            // the files, and saying "done" over data that is still there would
            // be the worst possible answer on this particular button.
            EraseResultBar.Severity = InfoBarSeverity.Warning;
            EraseResultBar.Title = "一部を消去できませんでした";
            EraseResultBar.Message =
                $"{result.Removed.Count} 件を削除し、{result.Failed.Count} 件が残りました。"
                + "変換エンジンが使用中の可能性があります。しばらく待ってからもう一度お試しください。";
        }

        RefreshEraseSummary();
    }
}
