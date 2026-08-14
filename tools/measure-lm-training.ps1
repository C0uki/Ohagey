# What does training a base language model cost? (decision 0034)
#
# Ohagey needs its own base model, and before anyone chooses a corpus size it is
# worth knowing what that size costs to train: wall time, peak memory, and the
# size of the tries that come out. `trainNGram` builds every count in memory
# before writing, so the interesting question is where that stops fitting.
#
# Reports a row per sample size so the shape is visible rather than one number
# extrapolated from a guess.
#
#   .\tools\measure-lm-training.ps1 -Corpus C:\swb\corpus\wikipedia-ja.txt

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Corpus,
    # Prefixes of the corpus, so every run trains on a superset of the last.
    [int[]]$Lines = @(2000, 5000, 10000, 20000, 40000),
    [string]$Trainer = "C:\swb\13c57d\x86_64-unknown-windows-msvc\release\OhageyLMTrain.exe",
    [string]$WorkDirectory = "C:\swb\lmcost",
    [string]$BackendDirectory = ""
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Trainer)) {
    throw "no trainer at $Trainer — build it first (swift build -c release --scratch-path C:\swb\13c57d)"
}

# llama.dll has to be findable: EfficientNGram is in a package built against it.
if (-not $BackendDirectory) {
    $BackendDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) "backends\cpu"
}
$env:PATH = "$BackendDirectory;$env:PATH"

$all = [System.IO.File]::ReadAllLines($Corpus)
Write-Host "corpus: $Corpus  ($($all.Count) lines)"
Write-Host ""

$rows = @()
foreach ($n in $Lines) {
    if ($n -gt $all.Count) {
        Write-Host "skipping $n — the corpus only has $($all.Count) lines"
        continue
    }

    $slice = $all[0..($n - 1)]
    $sampleDir = Join-Path $WorkDirectory "n$n"
    New-Item -ItemType Directory -Force $sampleDir | Out-Null
    $samplePath = Join-Path $sampleDir "corpus.txt"
    [System.IO.File]::WriteAllLines($samplePath, $slice, [System.Text.UTF8Encoding]::new($false))

    $distinct = (($slice -join '').ToCharArray() | Select-Object -Unique).Count

    # Peak working set rather than the size at the end: the trainer builds the
    # counts in dictionaries and then writes tries, so the high-water mark is
    # in the middle and is what decides whether a corpus fits at all.
    $process = Start-Process -PassThru -NoNewWindow -FilePath $Trainer `
        -ArgumentList @($samplePath, $sampleDir, "lm") `
        -RedirectStandardOutput (Join-Path $sampleDir "train.log")

    # Sampled while it runs, not read afterwards. `PeakWorkingSet64` comes
    # back as 0 once the process has exited — the counter lives in the
    # process, and reading it from a Process object whose target is gone
    # reports nothing rather than failing, which is how a whole column of
    # zeroes got measured the first time.
    $peak = 0
    while (-not $process.HasExited) {
        try {
            $process.Refresh()
            if ($process.WorkingSet64 -gt $peak) { $peak = $process.WorkingSet64 }
        } catch { }
        Start-Sleep -Milliseconds 100
    }
    $process.WaitForExit()

    $bytes = (Get-ChildItem $sampleDir -Filter "lm_*.marisa" | Measure-Object Length -Sum).Sum
    $rows += [pscustomobject]@{
        Lines      = $n
        Characters = ($slice | Measure-Object -Property Length -Sum).Sum
        Distinct   = $distinct
        Seconds    = [math]::Round(($process.ExitTime - $process.StartTime).TotalSeconds, 1)
        PeakMB     = [math]::Round($peak / 1MB, 0)
        ModelMB    = [math]::Round($bytes / 1MB, 1)
    }
    $rows[-1] | Format-Table -HideTableHeaders | Out-String | Write-Host -NoNewline
}

Write-Host ""
$rows | Format-Table -AutoSize
Write-Host ""
Write-Host "Lines      corpus lines trained on"
Write-Host "Characters total characters in those lines"
Write-Host "Distinct   distinct characters (the vocabulary the model can cover)"
Write-Host "Seconds    wall time for one training run"
Write-Host "PeakMB     peak working set, sampled every 100ms while training"
Write-Host "ModelMB    the five .marisa files together"
