# Draws the language bar icons (decision 0033).
#
# ── Why these are generated ─────────────────────────────────────────────────
#
# The vendored sample is a Simplified Chinese pinyin IME, and its icons are not
# decoration -- they are *characters*:
#
#     ImeModeOn.ico    中     ImeModeOff.ico   英     SampleIme.ico    样
#
# 中 / 英 is the Chinese input indicator, and 样 is a simplified-only form. So
# selecting Ohagey put a Chinese character in the taskbar, which is what the
# first user to try it reported as "中国語判定になる" -- correctly. Nothing was
# misregistered; the picture simply said Chinese.
#
# The Japanese convention is あ for kana input and A for alphanumeric, which is
# what every Japanese IME on the machine already shows.
#
# Regenerated rather than hand-drawn so the set stays consistent and the reason
# for each glyph is written down next to it.

[CmdletBinding()]
param(
    [string]$Destination = "",
    # Matches the candidate window (Define.h). Rendering Japanese in a Chinese
    # face is the same mistake one level down.
    [string]$FontFamily = "Yu Gothic UI"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

if (-not $Destination) {
    $Destination = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "SampleIME\image"
}
if (-not (Test-Path $Destination)) { throw "no image directory at $Destination" }

# The sizes the originals carried. Windows picks per DPI, and a missing size is
# scaled from another -- which is exactly how a crisp 16px glyph turns to mush.
$sizes = 16, 20, 24, 32, 40, 48

function New-GlyphIcon {
    param([string]$Glyph, [string]$Path, [single]$Fill = 0.78)

    $streams = @()
    foreach ($size in $sizes) {
        # ::new() rather than New-Object: New-Object picks its overload from a
        # PowerShell array and got Font's wrong, failing with a type error that
        # named neither the constructor nor the argument.
        $bmp = [System.Drawing.Bitmap]::new(
            [int]$size, [int]$size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.Clear([System.Drawing.Color]::Transparent)

        # Sized to the box rather than to a point size: these are read at 16px
        # on a taskbar, where a glyph that does not fill the square is a smudge.
        $font = [System.Drawing.Font]::new(
            [string]$FontFamily,
            [single]($size * $Fill),
            [System.Drawing.FontStyle]::Bold,
            [System.Drawing.GraphicsUnit]::Pixel)
        $format = [System.Drawing.StringFormat]::new()
        $format.Alignment = [System.Drawing.StringAlignment]::Center
        $format.LineAlignment = [System.Drawing.StringAlignment]::Center

        $rect = [System.Drawing.RectangleF]::new([single]0, [single]0, [single]$size, [single]$size)
        $g.DrawString($Glyph, $font, [System.Drawing.Brushes]::Black, $rect, $format)
        $g.Dispose()

        $ms = [System.IO.MemoryStream]::new()
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        # A pscustomobject rather than a nested array: @() flattens the
        # byte[] into the outer array, so $entry[1] came back as the first
        # *byte* of the PNG.
        $streams += [pscustomobject]@{ Size = $size; Bytes = $ms.ToArray() }
    }

    # ICO container, assembled as bytes rather than through BinaryWriter:
    # its Write() overloads bind by argument type, and PowerShell resolving
    # [byte]/[uint16]/[uint32]/byte[] across six calls is a source of errors
    # that name no line.
    #
    # Every entry is PNG-compressed, which Windows has read since Vista and
    # which avoids hand-building a DIB with its upside-down rows and the
    # doubled height for the AND mask.
    $header = [System.Collections.Generic.List[byte]]::new()
    $header.AddRange([BitConverter]::GetBytes([uint16]0))              # reserved
    $header.AddRange([BitConverter]::GetBytes([uint16]1))              # type: icon
    $header.AddRange([BitConverter]::GetBytes([uint16]$streams.Count))

    $offset = 6 + 16 * $streams.Count
    foreach ($entry in $streams) {
        $header.Add([byte]$entry.Size)                                 # width
        $header.Add([byte]$entry.Size)                                 # height
        $header.Add([byte]0)                                           # palette: none
        $header.Add([byte]0)                                           # reserved
        $header.AddRange([BitConverter]::GetBytes([uint16]1))           # colour planes
        $header.AddRange([BitConverter]::GetBytes([uint16]32))          # bits per pixel
        $header.AddRange([BitConverter]::GetBytes([uint32]$entry.Bytes.Length))
        $header.AddRange([BitConverter]::GetBytes([uint32]$offset))
        $offset += $entry.Bytes.Length
    }
    foreach ($entry in $streams) { $header.AddRange($entry.Bytes) }
    [System.IO.File]::WriteAllBytes($Path, $header.ToArray())
    "{0,-24} {1}  ({2:N0} bytes)" -f (Split-Path $Path -Leaf), $Glyph, (Get-Item $Path).Length
}

# あ / A: what every Japanese IME on the machine shows, so Ohagey reads the same
# way as the one beside it rather than announcing a different language.
New-GlyphIcon -Glyph "あ" -Path (Join-Path $Destination "ImeModeOn.ico")
New-GlyphIcon -Glyph "A"  -Path (Join-Path $Destination "ImeModeOff.ico")

# The text service's own icon. お for おはぎー -- the sample's 样 is a
# simplified-only form and says "Chinese" at a glance.
New-GlyphIcon -Glyph "お" -Path (Join-Path $Destination "SampleIme.ico")

# 全 / 半 are the same in both languages, so the width pair is left as it came.
Write-Host ""
Write-Host "DoubleSingleByte*/Punctuation* left alone: 全/半 and the punctuation"
Write-Host "marks read the same in Japanese."
