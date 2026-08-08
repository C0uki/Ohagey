# Builds the base language model Ohagey ships (decisions 0008 / 0009 / 0034).
#
# ── Why Ohagey trains its own ───────────────────────────────────────────────
#
# The published `Miwa-Keita/base_n5_lm` cannot be used for two independent
# reasons (decision 0034):
#
#   * it ships four of the five files, and `SwiftTrainer(baseFilePattern:)`
#     needs five. Without the fifth the personal model has to be trained from
#     nothing, which is what breaks 8 to 18 of 30 unrelated conversions;
#   * it states no licence at all.
#
# Both go away with a model we build. This produces it.
#
# ── The corpus is an input, not something this fetches ──────────────────────
#
# `fetch-wikipedia-corpus.ps1` samples articles at *random*, so running it twice
# gives two different corpora and two different models. A shipped artefact has
# to be reproducible, so the corpus is fetched once, archived beside the model,
# and passed in here. Keeping it is also the honest reading of CC BY-SA: the
# text the model was derived from should be available, not just the model.
#
# ── Size ────────────────────────────────────────────────────────────────────
#
# 10,000 sentences by default, which comes out around 9.4 MB. That number is
# chosen by what it costs the *user*, not by what it costs to build: the
# personal model is trained by resuming from this one, so it ends up the same
# size, and every retraining run costs roughly a second and 48 MB of peak memory
# per megabyte of base. Matching the published model's 42.6 MB would mean 41
# seconds and 2 GB on the user's machine every time they correct a few words.
# Measured in decision 0034; 9.4 MB scores the same 30/30 on the evaluation set.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Corpus,
    [string]$Destination = "C:\swb\basev1",
    # Prefix the engine looks for beside the Zenzai weights
    # (EnginePaths.baseLanguageModelPrefix).
    [string]$Prefix = "lm",
    [int]$Lines = 10000,
    [string]$Trainer = "C:\swb\13c57d\x86_64-unknown-windows-msvc\release\OhageyLMTrain.exe",
    [string]$BackendDirectory = ""
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Trainer)) {
    throw "no trainer at $Trainer — swift build -c release --scratch-path C:\swb\13c57d"
}
if (-not $BackendDirectory) {
    $BackendDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) "backends\cpu"
}
$env:PATH = "$BackendDirectory;$env:PATH"

New-Item -ItemType Directory -Force $Destination | Out-Null

# The slice is written out rather than passed through, so the exact input that
# produced these hashes is archived next to them.
$all = [System.IO.File]::ReadAllLines($Corpus)
if ($all.Count -lt $Lines) { throw "$Corpus has $($all.Count) lines, need $Lines" }
$slice = $all[0..($Lines - 1)]
$archived = Join-Path $Destination "corpus.txt"
[System.IO.File]::WriteAllLines($archived, $slice, [System.Text.UTF8Encoding]::new($false))

$licence = [System.IO.Path]::ChangeExtension($Corpus, ".LICENSE.txt")
if (Test-Path $licence) { Copy-Item $licence (Join-Path $Destination "corpus.LICENSE.txt") -Force }

Write-Host "corpus: $Lines lines, $((($slice | Measure-Object -Property Length -Sum).Sum)) characters"
Write-Host "training..."

& $Trainer $archived $Destination $Prefix | Select-Object -Last 8

Write-Host ""
Write-Host "SHA-256 (paste into installer\ohagey.iss):"
$total = 0
foreach ($suffix in "_c_abc", "_c_bc", "_r_xbx", "_u_abx", "_u_xbc") {
    $path = Join-Path $Destination "$Prefix$suffix.marisa"
    if (-not (Test-Path $path)) { throw "trainer did not write $path" }
    $total += (Get-Item $path).Length
    "{0,-16} {1}" -f "$Prefix$suffix.marisa", (Get-FileHash $path -Algorithm SHA256).Hash
}
"{0,-16} {1}" -f "corpus.txt", (Get-FileHash $archived -Algorithm SHA256).Hash

Write-Host ""
Write-Host ("model: {0:N1} MB in five files" -f ($total / 1MB))
Write-Host "Publish all five, plus corpus.txt and corpus.LICENSE.txt, as release"
Write-Host "assets. The installer downloads the five; the corpus is there because"
Write-Host "CC BY-SA is a share-alike licence and the model is derived from it."
