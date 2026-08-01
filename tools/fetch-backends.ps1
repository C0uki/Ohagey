# Fetches the llama.cpp builds Zenzai runs on (decisions 0028 / 0034).
#
# ── Why not build them ──────────────────────────────────────────────────────
#
# azooKey publishes Windows binaries for the exact fork and tag the converter
# needs, one per backend. Building them here would mean a CUDA toolkit and a
# Vulkan SDK on every developer's machine and in CI, to reproduce something
# already published by the people whose fork it is.
#
# ── Why azooKey/llama.cpp and not upstream ──────────────────────────────────
#
# The zenz model uses a Japanese character pre-tokenizer that exists only in
# azooKey's fork. Build against ggml-org/llama.cpp and everything links, starts
# and converts — from the dictionary, because the weights are rejected. See
# docs/local-setup.md.
#
# ── Why azooKey/llama.cpp and not fkunn1326's ───────────────────────────────
#
# azooKey-Windows downloads the same binaries from fkunn1326/llama.cpp, a fork
# of upstream held by an individual. These DLLs end up inside every application
# the user types in, so they come from the same organisation as the converter
# itself rather than from a third party, even though the contents are the same.

[CmdletBinding()]
param(
    # cpu is the default because it is the one that always works: no driver, no
    # device, no vendor runtime. CUDA is a 192 MB download, so it is opt-in.
    [ValidateSet("cpu", "cuda", "vulkan")]
    [string[]]$Backends = @("cpu"),

    [string]$Destination = (Join-Path (Split-Path $PSScriptRoot -Parent) "backends"),

    # Pinned with the converter: AzooKeyKanaKanjiConverter 0.8.5 and llama.cpp
    # b4846 cannot move independently (decision 0028).
    [string]$Tag = "b4846",

    [switch]$Force
)

$ErrorActionPreference = "Stop"

$assets = @{
    # avx, not avx2 or avx512: an IME that will not start on an older machine is
    # a worse trade than one that converts a little slower on a newer one.
    cpu    = "llama-$Tag-bin-win-avx-x64.zip"

    # Not yet verified: upstream ships the CUDA runtime as a separate
    # `cudart-llama-bin-win-*` asset, and azooKey's release has no such file. So
    # either this archive carries cudart/cublas itself or it expects a CUDA
    # installation on the machine. Which one decides whether the installer can
    # offer CUDA at all — settle it before wiring CUDA into the installer.
    cuda   = "llama-$Tag-bin-win-cuda-cu12.4-x64.zip"

    vulkan = "llama-$Tag-bin-win-vulkan-x64.zip"
}

$release = "https://github.com/azooKey/llama.cpp/releases/download/$Tag"
New-Item -ItemType Directory -Force $Destination | Out-Null

foreach ($backend in $Backends) {
    $target = Join-Path $Destination $backend
    if ((Test-Path (Join-Path $target "llama.dll")) -and -not $Force) {
        Write-Host "$backend : already present (use -Force to refetch)"
        continue
    }

    $asset = $assets[$backend]
    $zip = Join-Path $env:TEMP $asset
    Write-Host "$backend : downloading $asset"
    Invoke-WebRequest -Uri "$release/$asset" -OutFile $zip

    New-Item -ItemType Directory -Force $target | Out-Null
    Get-ChildItem $target -Filter *.dll | Remove-Item -Force
    # Flattened: the archives put the DLLs at the root, but expanding into a
    # nested directory would break the search path the engine sets up, which
    # points at exactly one folder per backend.
    $staging = Join-Path $env:TEMP "ohagey-llama-$backend"
    Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $staging
    Get-ChildItem $staging -Recurse -Filter *.dll | Copy-Item -Destination $target -Force

    # llama.lib is needed at link time and only once: the three backends are
    # ABI-compatible, so one import library serves all of them (which is the
    # whole reason a single build can switch between them at run time).
    if ($backend -eq "cpu") {
        $lib = Get-ChildItem $staging -Recurse -Filter "llama.lib" | Select-Object -First 1
        if ($lib) { Copy-Item $lib.FullName $Destination -Force }
    }

    Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
    Remove-Item $zip -Force -ErrorAction SilentlyContinue

    $size = (Get-ChildItem $target -Filter *.dll | Measure-Object Length -Sum).Sum / 1MB
    Write-Host ("$backend : {0} DLLs, {1:N1} MB" -f (Get-ChildItem $target -Filter *.dll).Count, $size)
}

Write-Host ""
Write-Host "backends in $Destination"
if (Test-Path (Join-Path $Destination "llama.lib")) {
    Write-Host ""
    Write-Host "to build the engine, LIB must include this directory:"
    Write-Host "  `$env:LIB = `"$Destination;`$env:LIB`""
    Write-Host ""
    Write-Host "the engine finds the DLLs itself, from backends\<name>\ beside the"
    Write-Host "executable — it does not use PATH (decision 0028)."
}
