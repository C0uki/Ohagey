# Renders the candidate window to a PNG so the drawing can be inspected without
# registering the text service (which needs administrator rights).
param([string]$OutputPng)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$out = Join-Path $here "build"
if (-not $OutputPng) { $OutputPng = Join-Path $out "candidate-preview.png" }

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

& cl.exe /nologo /std:c++17 /EHsc /utf-8 /W4 /WX /Zi `
    /Fo"$out\" /Fd"$out\preview.pdb" /Fe"$out\candidate-preview.exe" `
    (Join-Path $here "candidate-preview.cpp") `
    (Join-Path $here "..\CandidateRenderer.cpp") `
    (Join-Path $here "..\CandidateTheme.cpp") `
    /link kernel32.lib user32.lib gdi32.lib advapi32.lib d2d1.lib dwrite.lib dwmapi.lib
if ($LASTEXITCODE -ne 0) { throw "build failed" }

$bmp = Join-Path $out "candidate-preview.bmp"
Write-Host ""
& "$out\candidate-preview.exe" $bmp
if ($LASTEXITCODE -ne 0) { throw "preview failed" }

# BMP out of the harness, PNG for viewing: writing a BMP needs no image library,
# and System.Drawing is already here for the conversion.
Add-Type -AssemblyName System.Drawing
$image = [System.Drawing.Image]::FromFile($bmp)
try {
    $image.Save($OutputPng, [System.Drawing.Imaging.ImageFormat]::Png)
} finally {
    $image.Dispose()
}
Write-Host "png: $OutputPng"

Get-ChildItem $out -Filter *.obj -ErrorAction SilentlyContinue | Remove-Item -Force
