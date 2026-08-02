# Builds and runs the personalisation harness (decision 0034).
#
# Unlike build-and-run.ps1 this must *not* have an engine already running: it
# points the engine it launches at a scratch profile so the training does not
# land in the learning data you type against.
#
# The Zenzai model has to be installed, or set OHAGEY_MODEL_PATH first (debug
# builds only) — there is no neural ranking to personalise without it.
param([int]$NBest = 20, [string]$Reading = "", [string]$SeedCorpus = "", [switch]$KeepIntermediates)

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
# The reading is omitted rather than passed empty: the harness treats any
# argument as a reading, and an empty one converts nothing.
$harnessArgs = @($NBest)
# Positional, so a seed corpus needs a reading in front of it.
if ($Reading -or $SeedCorpus) { $harnessArgs += ($Reading ? $Reading : "きしゃのきしゃ") }
if ($SeedCorpus) { $harnessArgs += (Resolve-Path $SeedCorpus).Path }
& "$out\engine-personalization.exe" @harnessArgs
$exit = $LASTEXITCODE

if (-not $KeepIntermediates) {
    Get-ChildItem $out -Filter *.obj -ErrorAction SilentlyContinue | Remove-Item -Force
}
exit $exit
