# Does importing text for personalisation damage unrelated conversions?
# (decision 0037)
#
# Decision 0037 feeds user-supplied text into the personal n-gram that decision
# 0034 established is dangerous when built from nothing. Resuming from the base
# fixed that; this checks it stays fixed when the training input grows by two
# orders of magnitude.
#
# The assertion is the user dictionary's, applied to a document: *you may hand
# Ohagey your writing, but not at the cost of every other conversion.*
#
# `-Promotion` adds the other half: does an import actually lift a candidate?
# It swaps in a corpus written around one phrase and reads that phrase's rank
# before and after. Nothing is ever confirmed during the run, so a candidate
# that moves was moved by the imported text and not by the learning store —
# the mistake decision 0034 made three times.
#
# Needs the azooKey build of llama.cpp and an installed, resumable base model:
# without the fifth file the engine refuses to personalise at all and this
# would report a clean pass over a feature that never ran.
param(
    [string]$Text = '',
    [string]$EvalSet = '',
    # Resuming from the shipped 9.4 MB base costs about 8 seconds, and the duty
    # cycle can defer a run further. Measuring too early does not look like
    # measuring too early — it looks like the import having no effect at all.
    [int]$SettleSeconds = 30,
    # Measure whether the import promotes, not only whether it breaks things.
    [switch]$Promotion,
    # The pair has to satisfy two conditions to be measurable at all: the
    # learning store must not already promote it (nothing is confirmed here, so
    # that holds), and it must share its first character with rank 1 — upstream
    # does not personalise the first character (decision 0034).
    [string]$PromotionReading = 'ふくをきる',
    [string]$PromotionTarget = '服を切る',
    # How hard the personal model may push, in percent. The engine's default is
    # 100. Sweeping it is how "alpha 0.5 breaks nothing and moves nothing" gets
    # a number instead of a shrug (decision 0034).
    [int]$AlphaPercent = 100,
    [switch]$KeepIntermediates)

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
    /Fo"$out\" /Fd"$out\imported.pdb" /Fe"$out\engine-imported.exe" `
    (Join-Path $here "engine-imported.cpp") `
    (Join-Path $here "..\OhageyEngineClient.cpp") `
    (Join-Path $here "..\OhageyLog.cpp") `
    (Join-Path $here "..\OhageyWire.cpp") `
    /link kernel32.lib user32.lib advapi32.lib shell32.lib ole32.lib
if ($LASTEXITCODE -ne 0) { throw "build failed" }

# Stops rather than warns. Personalisation is the whole subject here, and
# without a resumable base the engine applies none of it — so a run without one
# would print a perfectly clean result about a feature that never executed.
. (Join-Path $here "base-lm-status.ps1")
Assert-OhageyBaseLm

# The promotion corpus is written around the target phrase, which is also the
# shape decision 0034 found most dangerous — one phrase, many times. Measuring
# both from one run is deliberate: a promotion bought by breaking the rest of
# the language is not a result worth having.
$default = if ($Promotion) { "imported-promotion-sample.txt" } else { "corpus-sample.txt" }
$text = if ($Text) { $Text } else { Join-Path $here $default }
$eval = if ($EvalSet) { $EvalSet } else { Join-Path $here "eval-set.tsv" }

$key = "HKCU:\Software\Ohagey"
$saved = $null
if (Test-Path $key) { $saved = Get-ItemProperty $key }

function Stop-Engine {
    $running = Get-Process OhageyEngine -ErrorAction SilentlyContinue
    if ($running) { $running | Stop-Process -Force; Start-Sleep -Milliseconds 750 }
}

$exit = 1
try {
    Stop-Engine
    # Personalisation on, explicitly. It is the default now, but a harness that
    # depends on a default measures whatever the default happens to be that
    # month — and this one is meaningless with it off.
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name "LearningEnabled" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $key -Name "PersonalizationEnabled" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $key -Name "PersonalizationAlphaPercent" -Value $AlphaPercent -PropertyType DWord -Force | Out-Null
    Write-Host "alpha: $AlphaPercent%"

    if ($Promotion) {
        & "$out\engine-imported.exe" $text $eval $SettleSeconds $PromotionReading $PromotionTarget
    } else {
        & "$out\engine-imported.exe" $text $eval $SettleSeconds
    }
    $exit = $LASTEXITCODE
} finally {
    Stop-Engine
    # The user's own settings back as they were — this key is not the harness's
    # to keep. Every name in the schema, or running a harness silently drops a
    # value the settings app wrote (see build-and-run-learning.ps1).
    Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
    if ($saved) {
        New-Item -Path $key -Force | Out-Null
        foreach ($name in @("SchemaVersion","LearningEnabled","PersonalizationEnabled",
                            "PersonalizationAlphaPercent","Backend","ZenzaiInferenceLimit",
                            "IdleTimeoutSeconds","DiagnosticLog")) {
            if ($null -ne $saved.$name) {
                $kind = if ($name -eq "Backend") { "String" } else { "DWord" }
                New-ItemProperty -Path $key -Name $name -Value $saved.$name -PropertyType $kind -Force | Out-Null
            }
        }
        Write-Host "`nrestored your settings key"
    } else {
        Write-Host "`nsettings key removed (it did not exist before this run)"
    }
}

if (-not $KeepIntermediates) {
    Get-ChildItem $out -Filter *.obj -ErrorAction SilentlyContinue | Remove-Item -Force
}

exit $exit
