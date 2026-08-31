# Builds and runs the user dictionary harness (decision 0026).
#
# Must NOT have an engine already running: it points the engine it launches at a
# scratch profile so the words it registers do not land in the dictionary you
# type against.
param([string]$EvalSet = "", [switch]$KeepIntermediates)

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
    (Join-Path $here "engine-userdict.cpp"),
    (Join-Path $here "..\OhageyEngineClient.cpp"),
    (Join-Path $here "..\OhageyWire.cpp")
)

& cl.exe /nologo /std:c++17 /EHsc /utf-8 /W4 /WX /Zi /DOHAGEY_ALLOW_ENGINE_PATH_OVERRIDE `
    /Fo"$out\" /Fd"$out\userdict.pdb" /Fe"$out\engine-userdict.exe" `
    $sources /link kernel32.lib user32.lib advapi32.lib
if ($LASTEXITCODE -ne 0) { throw "build failed" }

# The engine holds the pipe until it exits, and it is left running by design
# (decision 0015). A leftover from a previous run would make this refuse to
# start against the real profile.
$running = Get-Process OhageyEngine -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "stopping a leftover engine"
    $running | Stop-Process -Force
    Start-Sleep -Milliseconds 750
}

Write-Host ""
# The evaluation set is optional; omitted rather than passed empty, because
# PowerShell drops an empty argument and the harness would read the next one.
$harnessArgs = @()
if ($EvalSet) { $harnessArgs += (Resolve-Path $EvalSet).Path }
& "$out\engine-userdict.exe" @harnessArgs
$exit = $LASTEXITCODE

if (-not $KeepIntermediates) {
    Get-ChildItem $out -Filter *.obj -ErrorAction SilentlyContinue | Remove-Item -Force
}
exit $exit
