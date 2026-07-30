# Builds and runs the engine launch test (decisions 0015 / 0033).
#
# Requires that NO engine is running when it starts: the point is to watch the
# client start one.
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
    (Join-Path $here "engine-launch.cpp"),
    (Join-Path $here "..\OhageyEngineClient.cpp"),
    (Join-Path $here "..\OhageyWire.cpp"),
    (Join-Path $here "..\RomajiKana.cpp")
)

# OHAGEY_ALLOW_ENGINE_PATH_OVERRIDE lets the harness point at a built
# engine instead of one installed beside a DLL (decision 0033). The DLL
# project never defines it, so the override does not exist in a shipped
# build — it names an executable to run, which is not something an
# environment variable should decide in an IME.
& cl.exe /nologo /std:c++17 /EHsc /utf-8 /W4 /WX /Zi /DOHAGEY_ALLOW_ENGINE_PATH_OVERRIDE `
    /Fo"$out\" /Fd"$out\launch.pdb" /Fe"$out\engine-launch.exe" `
    $sources /link kernel32.lib user32.lib advapi32.lib
if ($LASTEXITCODE -ne 0) { throw "build failed" }

Write-Host ""
& "$out\engine-launch.exe"
$exit = $LASTEXITCODE

if (-not $KeepIntermediates) {
    Get-ChildItem $out -Filter *.obj -ErrorAction SilentlyContinue | Remove-Item -Force
}
exit $exit
