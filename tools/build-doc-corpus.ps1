# Builds a Japanese corpus out of this repository's own prose (decision 0034).
#
# ── Why the repo's own documents ────────────────────────────────────────────
#
# Measuring personalisation needs a base language model, and the published one
# cannot be resumed from (it ships four of the five files) and states no
# licence. Training our own needs a corpus.
#
# For the *experiments*, this is the right corpus precisely because it is
# unremarkable: it is text we wrote, so there is no licence question and no
# collection of anybody's typing (decisions 0016 / 0025), and it is already on
# the machine. It is Japanese technical prose about this project — narrow, and
# nowhere near what a shipped base model would need. That narrowness is stated
# in the decision log rather than hidden.
#
# ── What it is not ─────────────────────────────────────────────────────────
#
# Not a candidate for the base model Ohagey ships. That needs a broad, licensed
# corpus and is a separate piece of work. This exists so the mechanism can be
# tested before anyone spends time on the corpus.

[CmdletBinding()]
param(
    [string]$Root = (Split-Path $PSScriptRoot -Parent),
    [string]$Destination = "C:\swb\corpus\docs.txt",
    # Lines shorter than this are mostly headings and list markers, which teach
    # an n-gram very little and dilute the counts.
    [int]$MinimumLength = 8
)

$ErrorActionPreference = "Stop"

$files = Get-ChildItem (Join-Path $Root "docs") -Filter *.md -Recurse -File
Write-Host "reading $($files.Count) markdown files"

$sentences = [System.Collections.Generic.List[string]]::new()
$inFence = $false

foreach ($file in $files) {
    foreach ($raw in [System.IO.File]::ReadAllLines($file.FullName)) {
        # Code fences are shell commands and Swift, not Japanese. Left in, they
        # would teach the model that `$env:` is a common sequence.
        if ($raw -match '^\s*```') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }

        $line = $raw
        $line = $line -replace '`[^`]*`', ''                 # inline code
        $line = $line -replace '\[([^\]]*)\]\([^)]*\)', '$1'  # links, keep the text
        $line = $line -replace '^\s*[-*+]\s+', ''             # list markers
        $line = $line -replace '^\s*#{1,6}\s+', ''            # headings
        $line = $line -replace '^\s*>\s*', ''                 # quotes
        $line = $line -replace '\*\*|\*|~~', ''               # emphasis
        $line = $line -replace '\|', ' '                      # table cells
        $line = $line.Trim()
        if (-not $line) { continue }

        # Split into sentences. An n-gram is trained per line, so leaving whole
        # paragraphs would let counts run across sentence boundaries that a
        # reader would never cross.
        foreach ($piece in ($line -split '(?<=。)')) {
            $s = $piece.Trim()
            if ($s.Length -lt $MinimumLength) { continue }
            # Must actually contain Japanese: hiragana, katakana or kanji.
            if ($s -notmatch '[\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF]') { continue }
            $sentences.Add($s)
        }
    }
}

# Deduplicated: the decision log repeats phrases across addenda, and 8,200
# copies of 82 sentences taught this project a lesson once already — the
# vocabulary is what matters, not the line count (decision 0034, addendum 12).
$unique = $sentences | Select-Object -Unique

New-Item -ItemType Directory -Force (Split-Path $Destination) | Out-Null
[System.IO.File]::WriteAllLines($Destination, $unique, [System.Text.UTF8Encoding]::new($false))

$characters = ($unique -join '').ToCharArray() | Select-Object -Unique
Write-Host ""
Write-Host "$Destination"
Write-Host "  $($unique.Count) lines ($($sentences.Count) before dedup)"
Write-Host "  $($characters.Count) distinct characters"
