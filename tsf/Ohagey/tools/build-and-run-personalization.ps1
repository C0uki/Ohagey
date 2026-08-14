# Builds and runs the personalisation harness (decision 0034).
#
# Unlike build-and-run.ps1 this must *not* have an engine already running: it
# points the engine it launches at a scratch profile so the training does not
# land in the learning data you type against.
#
# The Zenzai model has to be installed, or set OHAGEY_MODEL_PATH first (debug
# builds only) — there is no neural ranking to personalise without it.
#
# Personalisation is switched on for the run and restored afterwards. It ships
# off (decision 0034, addendum 11), and a harness whose subject is off by
# default measures nothing — this one quietly started reporting "the target did
# not move" the moment the default changed.
param([int]$NBest = 20, [string]$Reading = "", [string]$SeedCorpus = "", [string]$EvalSet = "", [switch]$KeepIntermediates)

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

$sources = @(
    (Join-Path $here "engine-personalization.cpp"),
    (Join-Path $here "..\OhageyEngineClient.cpp"),
    (Join-Path $here "..\OhageyWire.cpp")
)

& cl.exe /nologo /std:c++17 /EHsc /utf-8 /W4 /WX /Zi /DOHAGEY_ALLOW_ENGINE_PATH_OVERRIDE `
    /Fo"$out\" /Fd"$out\p13n.pdb" /Fe"$out\engine-personalization.exe" `
    $sources /link kernel32.lib user32.lib advapi32.lib
if ($LASTEXITCODE -ne 0) { throw "build failed" }

Write-Host ""
# Without the base model this harness asserts that personalisation moved the
# target and is told, truthfully, that it did not — because there is nothing to
# personalise with. Stop instead of producing that FAIL (decision 0034).
. (Join-Path $here "base-lm-status.ps1")
Assert-OhageyBaseLm -Required

Write-Host ""
# The harness takes its arguments positionally, so a gap has to be filled
# rather than skipped. "-" stands for "not given": PowerShell drops an empty
# string when calling a native executable, which silently shifts every later
# argument down one. The evaluation set arrived as the seed corpus that way.
$harnessArgs = @($NBest)
if ($Reading -or $SeedCorpus -or $EvalSet) {
    $harnessArgs += ($Reading ? $Reading : "きしゃのきしゃ")
}
if ($SeedCorpus -or $EvalSet) {
    $harnessArgs += ($SeedCorpus ? (Resolve-Path $SeedCorpus).Path : "-")
}
if ($EvalSet) { $harnessArgs += (Resolve-Path $EvalSet).Path }

# HKCU\Software\Ohagey is the user's real settings key, so what is touched
# here is put back — including removing a value that was not there before.
$key = "HKCU:\Software\Ohagey"
$hadKey = Test-Path $key
if (-not $hadKey) { New-Item -Path $key | Out-Null }
$savedPersonalization = (Get-ItemProperty $key -ErrorAction SilentlyContinue).PersonalizationEnabled
Set-ItemProperty $key -Name PersonalizationEnabled -Value 1 -Type DWord

try {
    & "$out\engine-personalization.exe" @harnessArgs
    $exit = $LASTEXITCODE
}
finally {
    if ($null -ne $savedPersonalization) {
        Set-ItemProperty $key -Name PersonalizationEnabled -Value $savedPersonalization
    }
    else {
        Remove-ItemProperty $key -Name PersonalizationEnabled -ErrorAction SilentlyContinue
    }
}

if (-not $KeepIntermediates) {
    Get-ChildItem $out -Filter *.obj -ErrorAction SilentlyContinue | Remove-Item -Force
}
exit $exit
