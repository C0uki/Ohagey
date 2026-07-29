# Builds and runs the engine round-trip harness (decision 0032).
#
# A plain cl.exe invocation rather than a .vcxproj: this is a three-file
# developer tool, and giving it a project would mean carrying it through every
# solution-wide build for no benefit.
#
# Run from an "x64 Native Tools Command Prompt for VS 2022", or let this script
# find vcvars64 itself. OhageyEngine must already be running.
param([switch]$KeepIntermediates)

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

# /utf-8 so the Japanese literals in the harness are read as UTF-8 rather than
# the system code page. /W4 /WX because this code is the yardstick for the
# codec — warnings here are not acceptable noise.
$sources = @(
    (Join-Path $here "engine-roundtrip.cpp"),
    (Join-Path $here "..\OhageyEngineClient.cpp"),
    (Join-Path $here "..\OhageyWire.cpp"),
    (Join-Path $here "..\RomajiKana.cpp")
)

& cl.exe /nologo /std:c++17 /EHsc /utf-8 /W4 /WX /Zi `
    /Fo"$out\" /Fd"$out\harness.pdb" /Fe"$out\engine-roundtrip.exe" `
    $sources /link kernel32.lib user32.lib advapi32.lib
if ($LASTEXITCODE -ne 0) { throw "build failed" }

Write-Host ""
& "$out\engine-roundtrip.exe"
$exit = $LASTEXITCODE

if (-not $KeepIntermediates) {
    Get-ChildItem $out -Filter *.obj -ErrorAction SilentlyContinue | Remove-Item -Force
}
exit $exit
