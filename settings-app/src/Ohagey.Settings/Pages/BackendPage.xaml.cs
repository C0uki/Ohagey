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
        FillBackends(_loaded.Backend);
        // Maximum first, then Minimum, then Value: each assignment has to
        // leave the range consistent, and RangeBase throws rather than
        // coercing when it does not.
        InferenceLimit.Maximum = SettingsSchema.MaximumInferenceLimit;
        InferenceLimit.Minimum = SettingsSchema.MinimumInferenceLimit;
        InferenceLimit.Value = _loaded.ZenzaiInferenceLimit;
        // Same ordering rule as the slider, for the same reason.
        IdleTimeout.Maximum = SettingsSchema.MaximumIdleTimeoutSeconds;
        // Not the schema minimum: zero is how the setting is switched off, and
        // the switch above expresses that. Inside the box a zero would be a
        // second way to say the same thing, and the two could disagree.
        IdleTimeout.Minimum = 1;
        var exits = _loaded.IdleTimeoutSeconds > 0;
        IdleExitSwitch.IsOn = exits;
        // The box remembers a usable number even while the switch is off, so
        // turning it on does not demand a value before it can mean anything.
        // Five minutes is decision 0015's original figure.
        IdleTimeout.Value = exits ? _loaded.IdleTimeoutSeconds : 300;
        ShowIdleExit(exits);
        ModelStatus.Text = ModelState.Describe();
        ShowBackendStatus(_loaded.Backend);
        _loading = false;
    }

    /// <summary>Lists the backends, marking the ones this machine does not have.</summary>
    /// <remarks>
    /// A backend that is not installed stays in the list rather than
    /// disappearing: "CUDA — このインストーラーには含まれていません" answers the
    /// question a user came here with, and an absent row does not.
    ///
    /// The one exception is the backend already selected. It stays selectable
    /// even when missing, because the alternative is a combo box that cannot
    /// show what the registry actually holds — and this is exactly the state
    /// someone lands in when they choose CUDA and later reinstall without it.
    /// </remarks>
    private void FillBackends(Backend selected)
    {
        BackendChoice.Items.Clear();

        var index = 0;
        foreach (var backend in BackendAvailability.All)
        {
            var absence = BackendAvailability.ExplainAbsence(backend);
            var item = new ComboBoxItem
            {
                Content = absence is null
                    ? BackendAvailability.Name(backend)
                    : $"{BackendAvailability.Name(backend)} — {absence}",
                Tag = backend.ToString(),
                IsEnabled = absence is null || backend == selected,
            };

            BackendChoice.Items.Add(item);
            if (backend == selected) BackendChoice.SelectedIndex = index;
            index++;
        }
    }

    /// <summary>Shows the cost of switching idle exit on, and only then.</summary>
    /// <remarks>
    /// A warning that is always visible is one nobody reads. This one appears
    /// when the user has just asked for the thing it warns about.
    /// </remarks>
    private void ShowIdleExit(bool exits)
    {
        IdleTimeout.IsEnabled = exits;
        IdleExitNotice.IsOpen = exits;
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
        // Said before what the engine did, and about the selection rather than
        // the last run: a backend that is not on the machine explains the
        // status line underneath it, and it is true now rather than the next
        // time the engine starts.
        var absence = BackendAvailability.ExplainAbsence(selected);

        BackendStatusNotice.Message = absence is null
            ? BackendState.Describe(status, selected)
            : $"{BackendAvailability.Name(selected)} はこの端末にありません。{absence}\n"
              + BackendState.Describe(status, selected);

        BackendStatusNotice.Severity =
            absence is not null
            || (status is not null && status.Requested == selected && !status.IsHonoringRequest)
                ? InfoBarSeverity.Warning
                : InfoBarSeverity.Informational;
    }

    private void OnChanged(object sender, SelectionChangedEventArgs e) => Save();

    private void OnSliderChanged(object sender, RangeBaseValueChangedEventArgs e) => Save();

    private void OnIdleExitToggled(object sender, RoutedEventArgs e)
    {
        ShowIdleExit(IdleExitSwitch.IsOn);
        Save();
    }

    private void OnIdleTimeoutChanged(NumberBox sender, NumberBoxValueChangedEventArgs args) => Save();

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
            // Zero is off. NumberBox hands back NaN for an emptied box, which
            // (int) would turn into a large negative number — clamped to zero
            // on the way out, so an empty box would silently mean "stay
            // resident" while the switch said otherwise. Reading it as the
            // remembered five minutes keeps the two agreeing.
            IdleTimeoutSeconds = IdleExitSwitch.IsOn
                ? (double.IsNaN(IdleTimeout.Value) ? 300 : (int)IdleTimeout.Value)
                : 0,
        };

        _store.Write(updated);
        // Compared against what was on disk when this page opened, not against
        // the last keystroke: dragging the slider back to where it started
        // should stop claiming a restart is needed.
        RestartNotice.IsOpen = updated.SettingsRequiringRestart(_loaded).Count > 0;
        ShowBackendStatus(updated.Backend);
    }
}
