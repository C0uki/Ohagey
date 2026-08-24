# Measures whether the converter's own learning store is enough, with Zenzai
# genuinely loaded (decision 0034, re-examined).
#
# Runs the same measurement twice — personalisation off, then on — so the two
# can be told apart. The settings live in HKCU, which is the user's real
# settings key, so it is saved and restored around the run.
#
# Needs the azooKey build of llama.cpp: upstream's cannot load the zenz model,
# and this measures nothing without it. See docs/local-setup.md.
# `-Reading` matters more than it looks. Personalisation cannot move the
# first character of a candidate, so a reading whose alternatives all differ
# there measures the learning store alone. The default does exactly that;
# "きかいをつくる" offers 機会をつくる and 機会を作る, which share 機会を.
# `-SettleSeconds` has to grow with the base model: one retraining run takes
# about a second per megabyte of base (1.4 MB -> 1.2s, 42.6 MB -> 41s), and
# measuring before it lands looks exactly like personalisation not working.
param([string]$Reading = '', [int]$SettleSeconds = 20, [switch]$KeepIntermediates)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$out = Join-Path $here "build"

if (-not $env:VCINSTALLDIR) {
    $vcvars = "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"
    if (-not (Test-Path $vcvars)) {
        $vcvars = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    }
    if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found; run from an x64 Native Tools prompt" }
    foreach ($line in (cmd.exe /c "`"$vcvars`" && set")) {
        if ($line -match '^([^=]+)=(.*)$') {
            [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
        }
    }
}

New-Item -ItemType Directory -Force $out | Out-Null

& cl.exe /nologo /std:c++17 /EHsc /utf-8 /W4 /WX /Zi /DOHAGEY_ALLOW_ENGINE_PATH_OVERRIDE `
    /Fo"$out\" /Fd"$out\learning.pdb" /Fe"$out\engine-learning.exe" `
    (Join-Path $here "engine-learning.cpp") `
    (Join-Path $here "..\OhageyEngineClient.cpp") `
    (Join-Path $here "..\OhageyWire.cpp") `
    /link kernel32.lib user32.lib advapi32.lib
if ($LASTEXITCODE -ne 0) { throw "build failed" }

$key = "HKCU:\Software\Ohagey"
# Reported, not required: the first phase (learning store only) is a real
# measurement either way, and it is the second phase — the one whose whole point
# is the personal model — that the base model decides (decision 0034).
. (Join-Path $here "base-lm-status.ps1")
Assert-OhageyBaseLm

$saved = $null
if (Test-Path $key) { $saved = Get-ItemProperty $key }

function Stop-Engine {
    $running = Get-Process OhageyEngine -ErrorAction SilentlyContinue
    if ($running) { $running | Stop-Process -Force; Start-Sleep -Milliseconds 750 }
}

try {
    foreach ($phase in @(
        @{ Label = "learning store only (personalisation off)"; Personalization = 0 },
        @{ Label = "learning store + personalisation";          Personalization = 1 }
    )) {
        Stop-Engine
        New-Item -Path $key -Force | Out-Null
        New-ItemProperty -Path $key -Name "LearningEnabled" -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $key -Name "PersonalizationEnabled" -Value $phase.Personalization -PropertyType DWord -Force | Out-Null
        $reading = if ($Reading) { $Reading } else { 'きしゃのきしゃ' }
        & "$out\engine-learning.exe" $phase.Label $reading $SettleSeconds
    }
} finally {
    Stop-Engine
    # The user's own settings back as they were — this key is not the harness's
    # to keep.
    Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
    if ($saved) {
        New-Item -Path $key -Force | Out-Null
        # Every name in the schema, because this list is how the user gets
        # their settings back. A value added to SettingsSchema and forgotten
        # here is silently dropped from the real HKCU key by running a harness
        # — DiagnosticLog was added in decision 0033's addendum 19 and is the
        # reason this comment exists.
        foreach ($name in @("SchemaVersion","LearningEnabled","PersonalizationEnabled",
                            "PersonalizationAlphaPercent","Backend","ZenzaiInferenceLimit",
                            "IdleTimeoutSeconds","DiagnosticLog")) {
            if ($null -ne $saved.$name) {
                $kind = if ($name -eq "Backend") { "String" } else { "DWord" }
                New-ItemProperty -Path $key -Name $name -Value $saved.$name -PropertyType $kind -Force | Out-Null
            }
        }
        Write-Host "`nrestored your settings key"
    } else {
        Write-Host "`nsettings key removed (it did not exist before this run)"
    }
}

if (-not $KeepIntermediates) {
    Get-ChildItem $out -Filter *.obj -ErrorAction SilentlyContinue | Remove-Item -Force
}
