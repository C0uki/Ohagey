# Builds and runs the conversion-stability check (decisions 0032 / 0034).
#
# Converts one reading many times with nothing in between, and reports whether
# the answer ever differs. See engine-stability.cpp for why this matters — in
# short, the personalisation harness polls until it likes the answer, and that
# is only a measurement if conversion is deterministic.
#
# Must NOT have an engine already running: this starts one against a scratch
# profile.

param(
    [int]$NBest = 20,
    [int]$Rounds = 60,
    [switch]$KeepIntermediates
)

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
    /Fo"$out\" /Fd"$out\stability.pdb" /Fe"$out\engine-stability.exe" `
    (Join-Path $here "engine-stability.cpp") `
    (Join-Path $here "..\OhageyEngineClient.cpp") `
    (Join-Path $here "..\OhageyWire.cpp") `
    /link kernel32.lib user32.lib advapi32.lib
if ($LASTEXITCODE -ne 0) { throw "build failed" }

Write-Host ""
& "$out\engine-stability.exe" $NBest $Rounds
$exit = $LASTEXITCODE

if (-not $KeepIntermediates) {
    Get-ChildItem $out -Filter *.obj -ErrorAction SilentlyContinue | Remove-Item -Force
}
exit $exit
