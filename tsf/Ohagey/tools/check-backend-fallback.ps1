# Checks that a backend which cannot be loaded falls back to CPU, and that the
# settings app can find out (decision 0028).
#
# The case worth reproducing is not "the directory is missing" — that one is
# obvious and the layout code already handled it. It is the CUDA case: the
# backend's own llama.dll is right there, and the vendor runtime it depends on
# is not. Left to the delay-load helper that surfaces as a structured exception
# on the first conversion, so the engine dies mid-sentence and never gets to
# fall back at all.
#
# Simulated by copying a real llama.dll into a backend directory *without* the
# ggml DLLs beside it, which is the same failure the loader reports (126).
#
# The engine reads HKCU\Software\Ohagey, which is the user's real settings key,
# so it is saved and restored around the run.

param([switch]$KeepIntermediates)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$scratch = "C:\swb\13c57d"
$exe = Join-Path $scratch "x86_64-unknown-windows-msvc\debug\OhageyEngine.exe"
if (-not (Test-Path $exe)) { throw "build the engine first: swift build --scratch-path $scratch" }

$source = Join-Path $repo "backends\cpu"
if (-not (Test-Path (Join-Path $source "llama.dll"))) { throw "run tools\fetch-backends.ps1 first" }

# Beside the executable, which is where the engine looks (decision 0033).
$backends = Join-Path (Split-Path $exe -Parent) "backends"
Remove-Item -Recurse -Force $backends -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force (Join-Path $backends "cpu") | Out-Null
Copy-Item (Join-Path $source "*.dll") (Join-Path $backends "cpu")

# vulkan gets llama.dll and nothing else: present, unloadable.
New-Item -ItemType Directory -Force (Join-Path $backends "vulkan") | Out-Null
Copy-Item (Join-Path $source "llama.dll") (Join-Path $backends "vulkan")

$statusFile = Join-Path $env:LOCALAPPDATA "Ohagey\backend-status.tsv"
$key = "HKCU:\Software\Ohagey"

# Saved per value, and restored by *removing* the ones that were not there
# before. Leaving the last case's Backend behind would hand the user a setting
# they never chose — and this is their real settings key, the one the IME they
# type with reads. Note also that `New-Item -Force` on an existing registry key
# deletes its values, so the key is only created when it is genuinely absent.
$names = @("Backend", "IdleTimeoutSeconds")
$saved = @{}
if (Test-Path $key) {
    $existing = Get-ItemProperty $key
    foreach ($name in $names) {
        if ($null -ne $existing.$name) { $saved[$name] = $existing.$name }
    }
} else {
    New-Item -Path $key | Out-Null
}

function Invoke-Engine([string]$backend) {
    Set-ItemProperty $key -Name Backend -Value $backend
    Remove-Item $statusFile -Force -ErrorAction SilentlyContinue

    # Idle timeout so it exits on its own instead of waiting for a client. The
    # backend is chosen at startup, well before the accept loop.
    Set-ItemProperty $key -Name IdleTimeoutSeconds -Value 1 -Type DWord
    $log = & $exe 2>&1 | Out-String

    [pscustomobject]@{
        Backend = $backend
        Log     = ($log -split "`n" | Where-Object { $_ -match "backend:" }) -join "`n"
        Status  = if (Test-Path $statusFile) { (Get-Content $statusFile -Raw).Trim() } else { "(no status file)" }
    }
}

try {
    foreach ($case in @(
        @{ Backend = "cpu";    Expect = "installed and loadable — the ordinary case" }
        @{ Backend = "cuda";   Expect = "no directory at all — falls back, reason not-installed" }
        @{ Backend = "vulkan"; Expect = "llama.dll present, dependencies missing — falls back, reason load-failed" }
    )) {
        $result = Invoke-Engine $case.Backend
        Write-Host ("=" * 72)
        Write-Host "requested: $($case.Backend)  — $($case.Expect)"
        Write-Host ("-" * 72)
        Write-Host $result.Log
        Write-Host "--- backend-status.tsv ---"
        Write-Host $result.Status
        Write-Host ""
    }
}
finally {
    foreach ($name in $names) {
        if ($saved.ContainsKey($name)) { Set-ItemProperty $key -Name $name -Value $saved[$name] }
        else { Remove-ItemProperty $key -Name $name -ErrorAction SilentlyContinue }
    }
    if (-not $KeepIntermediates) { Remove-Item -Recurse -Force $backends -ErrorAction SilentlyContinue }
}
