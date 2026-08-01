# Measures what alpha buys and what it costs (decision 0034).
#
# Alpha is the one lever on personalisation's remaining limitation: confirming a
# candidate forty times promotes it, but also reorders candidates the user never
# touched. Turning alpha down should reduce the collateral — and, past some
# point, stop promoting the target at all. The roadmap has carried "40回確定
# すると他の候補も入れ替わる" as an open item without anyone measuring where
# that point is.
#
# Runs the personalisation harness once per alpha and reports both numbers side
# by side, so the default is chosen from a table rather than from azooKey-
# Desktop's choice of 1.0 (which is where the current default came from).
#
# HKCU\Software\Ohagey is the user's real settings key, so the values touched
# here are saved and restored — including removing ones that were not set.

param(
    # Percent, as the registry stores it (decision 0035). 150 is the maximum the
    # settings app offers; 0 is included as the control — it should promote
    # nothing, and a run that promotes at 0 means something else is doing it.
    [int[]]$AlphaPercent = @(0, 25, 50, 75, 100, 125, 150),
    [switch]$KeepIntermediates
)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$repo = (Resolve-Path (Join-Path $here "..\..\..")).Path

if (Get-Process OhageyEngine -ErrorAction SilentlyContinue) {
    throw "an OhageyEngine is already running; the harness starts its own against a scratch profile"
}

$key = "HKCU:\Software\Ohagey"
$names = @("PersonalizationAlphaPercent")
$saved = @{}
if (Test-Path $key) {
    $existing = Get-ItemProperty $key
    foreach ($name in $names) {
        if ($null -ne $existing.$name) { $saved[$name] = $existing.$name }
    }
} else {
    # Not `New-Item -Force`: on an existing registry key that deletes its values,
    # which here would be the user's settings.
    New-Item -Path $key | Out-Null
}

$results = @()
try {
    foreach ($alpha in $AlphaPercent) {
        Set-ItemProperty $key -Name PersonalizationAlphaPercent -Value $alpha -Type DWord
        while (Get-Process OhageyEngine -ErrorAction SilentlyContinue) {
            Get-Process OhageyEngine -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 400
        }

        $output = & (Join-Path $here "build-and-run-personalization.ps1") 2>&1 | Out-String
        $rank = [regex]::Match($output, "target: rank (\d+) -> (\d+)")
        $collateral = [regex]::Match($output, "collateral: (\d+) of (\d+)")

        $results += [pscustomobject]@{
            "alpha"      = $alpha / 100.0
            "from"       = if ($rank.Success) { [int]$rank.Groups[1].Value } else { $null }
            "to"         = if ($rank.Success) { [int]$rank.Groups[2].Value } else { $null }
            "promoted"   = $rank.Success -and [int]$rank.Groups[2].Value -eq 1
            "collateral" = if ($collateral.Success) { "$($collateral.Groups[1].Value)/$($collateral.Groups[2].Value)" } else { "-" }
        }
        $results[-1] | Format-Table -AutoSize -HideTableHeaders | Out-Host
    }
}
finally {
    foreach ($name in $names) {
        if ($saved.ContainsKey($name)) { Set-ItemProperty $key -Name $name -Value $saved[$name] }
        else { Remove-ItemProperty $key -Name $name -ErrorAction SilentlyContinue }
    }
    while (Get-Process OhageyEngine -ErrorAction SilentlyContinue) {
        Get-Process OhageyEngine -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
    }
}

Write-Host ""
$results | Format-Table -AutoSize
