# Measures what a personalisation training run costs, against corpus size
# (decision 0034).
#
# The roadmap left open whether the retraining threshold — 20 commits — can come
# down, because "I corrected the same word three times" currently does nothing.
# The answer depends on the cost, and the cost is not a constant: training reads
# the whole corpus every run, so it grows with how long someone has been using
# the IME. This measures that curve.
#
# Everything happens under a scratch LOCALAPPDATA, so nothing here touches the
# profile you type with.
#
# The base language model is copied in only to get past the engine's readiness
# check — whether it is the real one or the empty stand-in makes no difference
# here, because training reads the corpus and nothing else. Whether the base is
# real decides whether personalisation *affects ranking*, which decision 0034
# already settled; this measures cost.

param(
    [int[]]$CorpusSizes = @(100, 500, 1000, 2500, 5000, 10000),
    [switch]$KeepIntermediates
)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$out = Join-Path $here "build"
$engine = "C:\swb\13c57d\x86_64-unknown-windows-msvc\release\OhageyEngine.exe"

if (-not (Test-Path $engine)) {
    throw "build release first: swift build -c release --scratch-path C:\swb\13c57d"
}

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
    /Fo"$out\" /Fd"$out\cost.pdb" /Fe"$out\engine-training-cost.exe" `
    (Join-Path $here "engine-training-cost.cpp") `
    (Join-Path $here "..\OhageyEngineClient.cpp") `
    (Join-Path $here "..\OhageyWire.cpp") `
    /link kernel32.lib user32.lib advapi32.lib
if ($LASTEXITCODE -ne 0) { throw "build failed" }

# An engine started against the real profile would train on it. The harness
# launches its own, so any other one has to be out of the way first — they would
# also fight over the pipe name.
if (Get-Process OhageyEngine -ErrorAction SilentlyContinue) {
    throw "an OhageyEngine is already running; stop it first (it owns the pipe)"
}

$realLocalAppData = $env:LOCALAPPDATA
$baseSource = Join-Path $realLocalAppData "Ohagey\personal"
if (-not (Test-Path (Join-Path $baseSource "base_c_abc.marisa"))) {
    throw "no base model at $baseSource — start the engine once so it generates one"
}

# 20 is the threshold the engine trains at. Kept in step with
# PersonalLanguageModel.commitsPerTrainingRun; a mismatch would silently measure
# either nothing or two runs.
$threshold = 20
$results = @()

try {
    foreach ($size in $CorpusSizes) {
        $scratch = Join-Path $env:TEMP "ohagey-cost-$size"
        Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
        $personal = Join-Path $scratch "Ohagey\personal"
        New-Item -ItemType Directory -Force $personal | Out-Null
        Copy-Item (Join-Path $baseSource "base_*.marisa") $personal

        # Seeded short of the threshold so the run this triggers sees exactly
        # $size lines. Varied text: a corpus of one repeated line is not the
        # shape of anything an n-gram model would meet.
        $seed = [Math]::Max(0, $size - $threshold)
        if ($seed -gt 0) {
            $lines = 1..$seed | ForEach-Object { "これはコーパスの$($_)行目の文章です" }
            [System.IO.File]::WriteAllLines((Join-Path $personal "corpus.txt"), $lines)
        }

        $env:LOCALAPPDATA = $scratch
        $log = Join-Path $scratch "engine.log"
        $proc = Start-Process -FilePath $engine -RedirectStandardOutput $log `
            -RedirectStandardError (Join-Path $scratch "engine.err.log") `
            -WindowStyle Hidden -PassThru

        try {
            # The engine loads the dictionary before it listens.
            $deadline = (Get-Date).AddSeconds(30)
            while (-not (Select-String -Path $log -Pattern "listening" -Quiet -ErrorAction SilentlyContinue)) {
                if ((Get-Date) -gt $deadline) { throw "engine never started listening" }
                Start-Sleep -Milliseconds 200
            }

            & "$out\engine-training-cost.exe" $threshold | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "commit run failed for corpus size $size" }

            # Training is detached at utility priority, so the commits return
            # long before it finishes — which is the point of the design, and
            # the reason this waits on the log rather than on the client.
            $deadline = (Get-Date).AddSeconds(120)
            $published = $null
            while (-not $published) {
                $published = Select-String -Path $log -Pattern "generation \d+ published \((\d+) lines, (\d+)ms\)" `
                    -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $published) {
                    if ((Get-Date) -gt $deadline) { throw "training never finished for corpus size $size" }
                    Start-Sleep -Milliseconds 250
                }
            }

            $results += [pscustomobject]@{
                Lines        = [int]$published.Matches[0].Groups[1].Value
                Milliseconds = [int]$published.Matches[0].Groups[2].Value
            }
        }
        finally {
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
            $env:LOCALAPPDATA = $realLocalAppData
            if (-not $KeepIntermediates) {
                Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
            }
        }
    }
}
finally {
    $env:LOCALAPPDATA = $realLocalAppData
    if (-not $KeepIntermediates) {
        Get-ChildItem $out -Filter *.obj -ErrorAction SilentlyContinue | Remove-Item -Force
    }
}

Write-Host ""
$results
    | Select-Object Lines, Milliseconds, @{ n = "µs/line"; e = { [math]::Round($_.Milliseconds * 1000 / $_.Lines) } }
    | Format-Table -AutoSize
