using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Ohagey.Settings.Core;

namespace Ohagey.Settings.Pages;

public sealed partial class DictionaryPage : Page
{
    private readonly IUserDictionaryStore _store = new FileUserDictionaryStore();
    private List<UserDictionaryEntry> _entries = new();

    public DictionaryPage()
    {
        InitializeComponent();

        foreach (PartOfSpeech value in Enum.GetValues<PartOfSpeech>())
        {
            // The display name, not the file key: a dropdown reading
            // "propernoun" would be a bug even though nothing would break.
            PartOfSpeechChoice.Items.Add(new ComboBoxItem
            {
                Content = value.DisplayName(),
                Tag = value,
            });
        }
        PartOfSpeechChoice.SelectedIndex = 0;

        Load();
    }

    private void Load()
    {
        var (entries, skipped) = _store.Read();
        _entries = entries;
        Show();

        if (skipped.Count > 0)
        {
            // Said out loud rather than swallowed. A word someone typed in has
            // stopped working, and they would otherwise have no way to know.
            MessageBar.IsOpen = true;
            MessageBar.Severity = InfoBarSeverity.Warning;
            MessageBar.Title = "読み取れない行がありました";
            MessageBar.Message =
                $"{skipped.Count} 行を読み飛ばしました (行 {string.Join(", ", skipped.Take(10))})。"
                + "ほかの単語は読み込まれています。";
        }
    }

    private void Show()
    {
        EntryList.Items.Clear();
        foreach (var entry in _entries)
        {
            var row = new Grid { Padding = new Thickness(0, 4, 0, 4), ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(180) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(180) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            void Cell(string text, int column)
            {
                var block = new TextBlock { Text = text };
                Grid.SetColumn(block, column);
                row.Children.Add(block);
            }

            Cell(entry.Reading, 0);
            Cell(entry.Word, 1);
            Cell(entry.PartOfSpeech.DisplayName(), 2);

            EntryList.Items.Add(new ListViewItem { Content = row, Tag = entry });
        }

        DeleteButton.IsEnabled = _entries.Count > 0;
    }

    private void OnAddClicked(object sender, RoutedEventArgs e)
    {
        var partOfSpeech = (PartOfSpeech)((ComboBoxItem)PartOfSpeechChoice.SelectedItem).Tag;
        var entry = new UserDictionaryEntry(ReadingBox.Text.Trim(), WordBox.Text.Trim(), partOfSpeech);

        var problem = UserDictionary.Validate(entry);
        if (problem != UserDictionaryProblem.None)
        {
            MessageBar.IsOpen = true;
            MessageBar.Severity = InfoBarSeverity.Error;
            MessageBar.Title = "登録できません";
            MessageBar.Message = UserDictionary.Describe(problem);
            return;
        }

        // Replacing rather than appending: registering the same word again is
        // how someone corrects its part of speech, and two entries differing
        // only there would put two identical candidates in the list.
        _entries.RemoveAll(e => e.Reading == entry.Reading && e.Word == entry.Word);
        _entries.Add(entry);
        _store.Write(_entries);

        ReadingBox.Text = string.Empty;
        WordBox.Text = string.Empty;
        MessageBar.IsOpen = false;
        Show();
    }

    private void OnDeleteClicked(object sender, RoutedEventArgs e)
    {
        if (EntryList.SelectedItem is not ListViewItem { Tag: UserDictionaryEntry entry })
        {
            MessageBar.IsOpen = true;
            MessageBar.Severity = InfoBarSeverity.Informational;
            MessageBar.Title = "削除する単語を選んでください";
            MessageBar.Message = string.Empty;
            return;
        }

        _entries.Remove(entry);
        _store.Write(_entries);
        MessageBar.IsOpen = false;
        Show();
    }
}
