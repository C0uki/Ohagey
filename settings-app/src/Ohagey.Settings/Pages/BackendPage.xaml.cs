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
        ShowBackendStatus(_loaded.Backend);
        _loading = false;
    }

    /// <summary>
    /// Says what the engine actually loaded last time it started.
    /// </summary>
    /// <remarks>
    /// Re-read on every change rather than cached with the page: the status is
    /// compared against the currently selected backend, so switching the combo
    /// box has to move it from "running on CPU" to "will use CUDA next time".
    ///
    /// Severity is raised only when the engine is not doing what was asked. A
    /// warning on the ordinary case would train the user to ignore it, which is
    /// the opposite of what decision 0028 wants from this line.
    /// </remarks>
    private void ShowBackendStatus(Backend selected)
    {
        var status = BackendStatusFile.Read();
        BackendStatusNotice.Message = BackendState.Describe(status, selected);
        BackendStatusNotice.Severity =
            status is not null && status.Requested == selected && !status.IsHonoringRequest
                ? InfoBarSeverity.Warning
                : InfoBarSeverity.Informational;
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
        ShowBackendStatus(updated.Backend);
    }
}
