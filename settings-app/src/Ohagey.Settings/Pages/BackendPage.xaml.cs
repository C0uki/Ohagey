using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Ohagey.Settings.Core;

namespace Ohagey.Settings.Pages;

public sealed partial class BackendPage : Page
{
    private readonly ISettingsStore _store = new RegistrySettingsStore();
    private EngineSettings _loaded;
    // Set while the controls are being filled in, so restoring the saved state
    // does not read as the user changing it and write the file back.
    private bool _loading;

    public BackendPage()
    {
        InitializeComponent();
        _loaded = _store.Read();
        Load();
    }

    private void Load()
    {
        _loading = true;
        BackendChoice.SelectedIndex = _loaded.Backend switch
        {
            Backend.Cuda => 1,
            Backend.Vulkan => 2,
            _ => 0,
        };
        // Maximum first, then Minimum, then Value: each assignment has to
        // leave the range consistent, and RangeBase throws rather than
        // coercing when it does not.
        InferenceLimit.Maximum = SettingsSchema.MaximumInferenceLimit;
        InferenceLimit.Minimum = SettingsSchema.MinimumInferenceLimit;
        InferenceLimit.Value = _loaded.ZenzaiInferenceLimit;
        ModelStatus.Text = ModelState.Describe();
        _loading = false;
    }

    private void OnChanged(object sender, SelectionChangedEventArgs e) => Save();

    private void OnSliderChanged(object sender, RangeBaseValueChangedEventArgs e) => Save();

    private void Save()
    {
        if (_loading) return;

        var updated = _loaded with
        {
            Backend = (BackendChoice.SelectedItem as ComboBoxItem)?.Tag switch
            {
                "Cuda" => Backend.Cuda,
                "Vulkan" => Backend.Vulkan,
                _ => Backend.Cpu,
            },
            ZenzaiInferenceLimit = (int)InferenceLimit.Value,
        };

        _store.Write(updated);
        // Compared against what was on disk when this page opened, not against
        // the last keystroke: dragging the slider back to where it started
        // should stop claiming a restart is needed.
        RestartNotice.IsOpen = updated.SettingsRequiringRestart(_loaded).Count > 0;
    }
}
