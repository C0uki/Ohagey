// Which backends the settings app may offer (decision 0028).
//
// The point of these is the asymmetry: a GPU backend missing is an ordinary
// machine (the default installer ships CPU only), while CPU missing is a
// damaged install. The UI says different things about the two, so the two have
// to be told apart here rather than in the page.

using Ohagey.Settings.Core;
using Xunit;

namespace Ohagey.Settings.Core.Tests;

public class BackendAvailabilityTests
{
    [Fact]
    public void ABackendIsInstalledWhenLlamaDllIsBesideIt()
    {
        var root = MakeBackends(Backend.Cpu, Backend.Vulkan);
        try
        {
            Assert.True(BackendAvailability.IsInstalled(Backend.Cpu, root));
            Assert.True(BackendAvailability.IsInstalled(Backend.Vulkan, root));
            Assert.False(BackendAvailability.IsInstalled(Backend.Cuda, root));

            Assert.Equal(
                new[] { Backend.Cpu, Backend.Vulkan },
                BackendAvailability.Installed(root));
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public void AnEmptyDirectoryIsNotAnInstalledBackend()
    {
        // fetch-backends.ps1 creates the directory before it has fetched
        // anything, and an interrupted download leaves the ggml DLLs without
        // llama.dll. Both look installed to a directory-exists check, and the
        // engine would then fall back to CPU while the app claimed otherwise.
        var root = MakeBackends();
        Directory.CreateDirectory(Path.Combine(root, "cuda"));
        File.WriteAllText(Path.Combine(root, "cuda", "ggml-cuda.dll"), "");
        try
        {
            Assert.False(BackendAvailability.IsInstalled(Backend.Cuda, root));
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public void ADirectoryThatDoesNotExistLeavesEverythingUnavailable()
    {
        // The settings app runs on machines where Ohagey is not installed at
        // all -- someone building it from source, for one. Asking has to be
        // safe there, because the page asks while it is drawing itself.
        var missing = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());

        Assert.Empty(BackendAvailability.Installed(missing));
        Assert.False(BackendAvailability.IsInstalled(Backend.Cpu, missing));
    }

    [Fact]
    public void MissingCpuReadsAsADamagedInstallRatherThanAPackagingChoice()
    {
        // CPU ships unconditionally: `iscc /DGpuBackends` decides the other
        // two. So "the installer did not include it" is true of CUDA and
        // Vulkan and false of CPU, and telling the user to look for a GPU
        // installer would send them after something that does not exist.
        var root = MakeBackends(Backend.Vulkan);
        try
        {
            var cpu = BackendAvailability.ExplainAbsence(Backend.Cpu, root);
            var cuda = BackendAvailability.ExplainAbsence(Backend.Cuda, root);

            Assert.NotNull(cpu);
            Assert.NotNull(cuda);
            Assert.NotEqual(cpu, cuda);
            Assert.Null(BackendAvailability.ExplainAbsence(Backend.Vulkan, root));
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public void TheDirectoryNamesAreTheOnesTheRegistryHolds()
    {
        // The engine resolves backends\<name>\ from the same lowercase string
        // it reads out of the registry (BackendLayout.directoryName). A
        // capitalised name here would look for a directory the installer never
        // creates, and every backend would read as missing.
        Assert.Equal("cpu", BackendAvailability.DirectoryNameFor(Backend.Cpu));
        Assert.Equal("cuda", BackendAvailability.DirectoryNameFor(Backend.Cuda));
        Assert.Equal("vulkan", BackendAvailability.DirectoryNameFor(Backend.Vulkan));
    }

    [Fact]
    public void OnlyLlamaDllDecidesIt()
    {
        // Pinned because the engine probes exactly this one file
        // (BackendLayout.probeLibrary). Checking more here would refuse a
        // backend the engine would happily load.
        Assert.Equal("llama.dll", BackendAvailability.ProbeLibrary);
    }

    /// <summary>A backends directory holding llama.dll for each named backend.</summary>
    private static string MakeBackends(params Backend[] installed)
    {
        var root = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
        Directory.CreateDirectory(root);
        foreach (var backend in installed)
        {
            var directory = Path.Combine(root, BackendAvailability.DirectoryNameFor(backend));
            Directory.CreateDirectory(directory);
            File.WriteAllText(Path.Combine(directory, BackendAvailability.ProbeLibrary), "");
        }
        return root;
    }
}
