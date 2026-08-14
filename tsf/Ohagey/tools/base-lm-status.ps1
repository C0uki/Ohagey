# Is the base language model installed? (decision 0034)
#
# Dot-sourced by the harnesses whose subject is personalisation. It exists
# because its absence is invisible at the point of measurement and silently
# turns those harnesses into measurements of nothing.
#
# What happened: the base model was fetched into a scratch directory and reached
# through `OHAGEY_BASE_LM_PATH`, which `EnginePaths` honours **in debug builds
# only**. A later session ran the same harnesses against a release build, got
# `2位 → 2位` where the log said `2位 → 1位`, and spent a long time looking for a
# regression in code that had not changed. There was none: without the base
# model, personalisation neither helps nor harms (0 of 30 eval items moved in
# either direction).
#
# The rule this encodes: a harness that cannot affect its subject must say so
# rather than report that the subject does nothing.

function Get-OhageyBaseLmStatus {
    # Mirrors EnginePaths.resolveBaseLanguageModelPrefix / the four suffixes in
    # EngineSettings.swift. Four, not five — the published model has no `_c_bc`.
    $suffixes = @("_c_abc", "_r_xbx", "_u_abx", "_u_xbc")

    $prefix = $env:OHAGEY_BASE_LM_PATH
    $viaOverride = [bool]$prefix
    if (-not $prefix) {
        $prefix = Join-Path ${env:ProgramFiles} "Ohagey\models\lm"
    }

    $missing = @($suffixes | Where-Object { -not (Test-Path "$prefix$_.marisa") })

    [pscustomobject]@{
        Prefix      = $prefix
        ViaOverride = $viaOverride
        Available   = ($missing.Count -eq 0)
        Missing     = $missing
    }
}

# Prints what was found. `-Required` turns a missing model into a hard stop,
# for harnesses that assert personalisation changed something — reporting
# "the target did not move" would be true and useless.
function Assert-OhageyBaseLm {
    param([switch]$Required)

    $status = Get-OhageyBaseLmStatus
    if ($status.Available) {
        $how = if ($status.ViaOverride) { "OHAGEY_BASE_LM_PATH" } else { "installed" }
        Write-Host "base language model: present ($how, $($status.Prefix))"
        if ($status.ViaOverride) {
            # Worth saying every time: the override is compiled out of release
            # builds, so the same command against a release engine measures
            # something else entirely.
            Write-Host "  NOTE: OHAGEY_BASE_LM_PATH is honoured by DEBUG builds only." -ForegroundColor Yellow
            Write-Host "        Point OHAGEY_ENGINE_PATH at a debug engine, or this is ignored." -ForegroundColor Yellow
        }
        return
    }

    Write-Host ""
    Write-Host "base language model: MISSING at $($status.Prefix)*.marisa" -ForegroundColor Yellow
    Write-Host "  Personalisation falls back to an empty base model, which is inert:"
    Write-Host "  it moves nothing and breaks nothing (decision 0034). Anything this"
    Write-Host "  harness reports about personalisation would be about that fallback."
    Write-Host ""
    Write-Host "  Fetch Miwa-Keita/base_n5_lm and either install it beside the Zenzai"
    Write-Host "  weights, or set OHAGEY_BASE_LM_PATH and use a DEBUG engine:"
    Write-Host '    $env:OHAGEY_BASE_LM_PATH = "C:\swb\base_n5_lm\lm"'
    Write-Host ""

    if ($Required) { throw "no base language model — this harness would measure nothing" }
}
