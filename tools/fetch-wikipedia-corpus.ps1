# Fetches Japanese sentences from Wikipedia for training a base model
# (decisions 0009 / 0034).
#
# ── Why Wikipedia ───────────────────────────────────────────────────────────
#
# The base language model personalisation needs has to come from somewhere, and
# the published one cannot be used: it states no licence and ships four of the
# five files, so the personal model cannot be trained from it (decision 0034).
#
# Wikipedia is CC BY-SA 4.0 — the same licence as the Zenzai weights, so
# decision 0009's arrangement already covers it: a separate artefact under a
# separate licence, attributed in the settings app, with Ohagey's own code
# staying MIT. It is also modern, broad, and its provenance is checkable, which
# rules in favour of it over a crawl (CC-100, OSCAR) whose contents nobody here
# can account for.
#
# ── This is a development tool ──────────────────────────────────────────────
#
# It is not part of the product and nothing in the shipped IME talks to the
# network beyond the install-time model download (decision 0016). It runs on a
# maintainer's machine when a base model needs building.
#
# ── Politeness ──────────────────────────────────────────────────────────────
#
# The API is asked for random articles in batches, with a descriptive
# User-Agent and a pause between calls, as Wikimedia's etiquette asks. Keep
# -Articles to what is actually needed.

[CmdletBinding()]
param(
    [int]$Articles = 1000,
    [string]$Destination = "C:\swb\corpus\wikipedia-ja.txt",
    # Sentences shorter than this are section stubs and list fragments; longer
    # than this are usually tables that survived the plain-text extraction.
    [int]$MinimumLength = 12,
    [int]$MaximumLength = 120,
    [int]$PauseMilliseconds = 300
)

$ErrorActionPreference = "Stop"

# The API caps extracts at 20 per request.
$batch = 20
$userAgent = "Ohagey-corpus-builder/0.1 (https://github.com/C0uki/Ohagey; base language model training)"
$endpoint = "https://ja.wikipedia.org/w/api.php"

$sentences = [System.Collections.Generic.HashSet[string]]::new()
$fetched = 0
$calls = [math]::Ceiling($Articles / $batch)

# ── Following the continuation ─────────────────────────────────────────
#
# `exlimit=20` does not mean twenty extracts arrive. MediaWiki caps how much
# text one response may carry and hands back a `continue` token for the
# rest: asking for twenty full articles returned **one**, with the other
# nineteen empty, which looks exactly like nineteen articles with no text.
# The batch is re-requested with the token until the generator is exhausted.
for ($i = 0; $i -lt $calls; $i++) {
    $continuation = @{}
    $guard = 0
    do {
        $uri = "$endpoint`?action=query&generator=random&grnnamespace=0&grnlimit=$batch" +
               "&prop=extracts&explaintext=1&exlimit=$batch&format=json&formatversion=2"
        foreach ($k in $continuation.Keys) { $uri += "&$k=$([uri]::EscapeDataString([string]$continuation[$k]))" }

        try {
            $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 60 -UserAgent $userAgent
        } catch {
            # One failed call is not a reason to lose the ones that worked.
            Write-Host "  call $($i + 1): $($_.Exception.Message)"
            Start-Sleep -Milliseconds ($PauseMilliseconds * 4)
            break
        }

        $json = $response.Content | ConvertFrom-Json
        foreach ($page in $json.query.pages) {
            if (-not $page.extract) { continue }
            $fetched++
            foreach ($line in ($page.extract -split "`n")) {
                $line = $line.Trim()
                if (-not $line) { continue }
                # Headings come through as "== 概要 ==".
                if ($line.StartsWith("=")) { continue }

                foreach ($piece in ($line -split '(?<=。)')) {
                    $t = $piece.Trim()
                    if ($t.Length -lt $MinimumLength -or $t.Length -gt $MaximumLength) { continue }
                    # Must actually be Japanese: hiragana, katakana or kanji.
                    if ($t -notmatch '[぀-ゟ゠-ヿ一-鿿]') { continue }
                    [void]$sentences.Add($t)
                }
            }
        }

        # Only the extract continuation is followed. Continuing the *generator*
        # would walk on to new random articles and never finish.
        $continuation = @{}
        if ($json.continue -and $json.continue.excontinue) {
            $continuation["excontinue"] = $json.continue.excontinue
            $continuation["continue"] = $json.continue.continue
        }
        $guard++
        Start-Sleep -Milliseconds $PauseMilliseconds
    } while ($continuation.Count -gt 0 -and $guard -lt ($batch + 2))

    if (($i + 1) % 5 -eq 0) {
        Write-Host "  $($i + 1)/$calls batches, $fetched articles, $($sentences.Count) sentences"
    }
}
New-Item -ItemType Directory -Force (Split-Path $Destination) | Out-Null
[System.IO.File]::WriteAllLines($Destination, $sentences, [System.Text.UTF8Encoding]::new($false))

# Provenance beside the corpus, not inside it: a header line in the corpus
# itself would be trained on.
$about = [System.IO.Path]::ChangeExtension($Destination, ".LICENSE.txt")
@(
    "Source: Japanese Wikipedia (ja.wikipedia.org), fetched $(Get-Date -Format 'yyyy-MM-dd') via the MediaWiki API",
    "Licence: CC BY-SA 4.0  https://creativecommons.org/licenses/by-sa/4.0/",
    "Articles sampled: $fetched (random, namespace 0)",
    "Sentences kept: $($sentences.Count)",
    "",
    "Attribution and share-alike apply to this text and to models derived from it.",
    "Ohagey's own code is MIT and unaffected; see docs/decisions/0009-model-license.md."
) | Set-Content -Path $about -Encoding UTF8

$characters = ($sentences -join '').ToCharArray() | Select-Object -Unique
Write-Host ""
Write-Host "$Destination"
Write-Host "  $fetched articles -> $($sentences.Count) sentences, $($characters.Count) distinct characters"
Write-Host "  provenance: $about"
