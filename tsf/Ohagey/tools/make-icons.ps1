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

# ICO container, assembled as bytes rather than through BinaryWriter: its
# Write() overloads bind by argument type, and PowerShell resolving
# [byte]/[uint16]/[uint32]/byte[] across six calls is a source of errors that
# name no line.
#
# Every entry is PNG-compressed, which Windows has read since Vista and which
# avoids hand-building a DIB with its upside-down rows and the doubled height
# for the AND mask.
function Write-IcoFile {
    param($Streams, [string]$Path)

    $out = [System.Collections.Generic.List[byte]]::new()
    $out.AddRange([BitConverter]::GetBytes([uint16]0))              # reserved
    $out.AddRange([BitConverter]::GetBytes([uint16]1))              # type: icon
    $out.AddRange([BitConverter]::GetBytes([uint16]$Streams.Count))

    $offset = 6 + 16 * $Streams.Count
    foreach ($entry in $Streams) {
        $out.Add([byte]$entry.Size)                                 # width
        $out.Add([byte]$entry.Size)                                 # height
        $out.Add([byte]0)                                           # palette: none
        $out.Add([byte]0)                                           # reserved
        $out.AddRange([BitConverter]::GetBytes([uint16]1))           # colour planes
        $out.AddRange([BitConverter]::GetBytes([uint16]32))          # bits per pixel
        $out.AddRange([BitConverter]::GetBytes([uint32]$entry.Bytes.Length))
        $out.AddRange([BitConverter]::GetBytes([uint32]$offset))
        $offset += $entry.Bytes.Length
    }
    foreach ($entry in $Streams) { $out.AddRange($entry.Bytes) }
    [System.IO.File]::WriteAllBytes($Path, $out.ToArray())
}

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

    Write-IcoFile -Streams $streams -Path $Path
    "{0,-24} {1}  ({2:N0} bytes)" -f (Split-Path $Path -Leaf), $Glyph, (Get-Item $Path).Length
}

# あ / A: what every Japanese IME on the machine shows, so Ohagey reads the same
# way as the one beside it rather than announcing a different language.
New-GlyphIcon -Glyph "あ" -Path (Join-Path $Destination "ImeModeOn.ico")
New-GlyphIcon -Glyph "A"  -Path (Join-Path $Destination "ImeModeOff.ico")

function New-OhagiIcon {
    param([string]$Path)

    # The text service's own icon, drawn rather than set in type.
    #
    # It appears in the Win+Space switcher and the input-method list, beside
    # Microsoft IME's mark -- a place where a letter competes with the あ/A the
    # mode indicator is already showing. A shape does not.
    #
    # Drawn as a silhouette, not an illustration: this is read at 16px, where
    # interior detail turns to grey mush. What survives at that size is the
    # outline, so the whole design is in the outline -- a lumpy mound (the
    # tsubu-an) sitting on a plate. The plate is what stops it reading as a
    # hill or a stone.
    $streams = @()
    foreach ($size in $sizes) {
        $bmp = [System.Drawing.Bitmap]::new(
            [int]$size, [int]$size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)

        $s = [single]$size
        $margin = $s * 0.09

        # Plate: a bar at the foot, at least one pixel so it survives 16px.
        $plateH = [Math]::Max(1.0, $s * 0.075)
        $plateY = $s - $margin - $plateH
        $g.FillRectangle([System.Drawing.Brushes]::Black,
            $margin, $plateY, $s - 2 * $margin, $plateH)

        # Body: wider than tall, sitting just above the plate.
        $gap = $s * 0.02
        $bodyBottom = $plateY - $gap
        $bodyLeft = $margin + $s * 0.07
        $bodyRight = $s - $margin - $s * 0.07
        $bodyW = $bodyRight - $bodyLeft
        $bodyH = $s * 0.40
        $bodyTop = $bodyBottom - $bodyH

        # A dome with three lumps breaking its top edge.
        #
        # Three attempts got here. Arcs joined end to end leave a valley as
        # deep as the bump is tall -- a castle with three towers. Overlapping
        # circles on a rectangle fixed the valleys but kept straight sides and
        # square corners, which read as a loaf. A free-floating oval read as a
        # stone, and swallowed lumps too small to break its outline.
        #
        # A dome sits *on* the plate, so the two shapes belong to each other,
        # and the lumps have to clear the outline to be seen at all.
        $shape = [System.Drawing.Drawing2D.GraphicsPath]::new()
        # 180 to 360 sweeps the top half of the ellipse, left to right;
        # CloseFigure lays the flat bottom back along the plate.
        $shape.AddArc($bodyLeft, $bodyBottom - $bodyH, $bodyW, $bodyH * 2, 180, 180)
        $shape.CloseFigure()
        $g.FillPath([System.Drawing.Brushes]::Black, $shape)
        $shape.Dispose()

        # Lumps, but only where there is room for them.
        #
        # At 16px a lump is under two pixels and does not read as texture; it
        # reads as a dent, and the whole mark starts looking like a hat. The
        # dome alone is unambiguous at that size, so the small sizes get the
        # dome and the large ones get the tsubu-an. Simplifying as the icon
        # shrinks is ordinary practice, and here it is the difference between
        # a confection and a smudge.
        if ($size -ge 32) {
            # Centred on the dome's own curve, so the outer pair sits on the
            # shoulders instead of hanging off them. dy is the ellipse's
            # sagitta at that offset: y = h * (1 - sqrt(1 - (2dx/w)^2)).
            $r = $bodyW * 0.145
            foreach ($i in -1, 0, 1) {
                $dx = $bodyW * 0.29 * $i
                $t = 2 * $dx / $bodyW
                $dy = $bodyH * (1 - [Math]::Sqrt([Math]::Max(0.0, 1 - $t * $t)))
                $cx = $bodyLeft + $bodyW / 2 + $dx
                # Sunk two thirds of the way in: enough to break the outline,
                # not enough to turn the middle one into a peak.
                $cy = $bodyBottom - $bodyH + $dy + $r * 0.7
                $g.FillEllipse([System.Drawing.Brushes]::Black,
                    $cx - $r, $cy - $r, $r * 2, $r * 2)
            }
        }

        $g.Dispose()

        $ms = [System.IO.MemoryStream]::new()
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $streams += [pscustomobject]@{ Size = $size; Bytes = $ms.ToArray() }
    }

    Write-IcoFile -Streams $streams -Path $Path
    "{0,-24} {1}  ({2:N0} bytes)" -f (Split-Path $Path -Leaf), "ohagi", (Get-Item $Path).Length
}

# The text service's own icon. An おはぎ, because the sample's 样 is a
# simplified-only form and says "Chinese" at a glance, and because a picture
# does not compete with the あ/A the mode indicator is showing next to it.
New-OhagiIcon -Path (Join-Path $Destination "SampleIme.ico")

# 全 / 半 are the same in both languages, so the width pair is left as it came.
Write-Host ""
Write-Host "DoubleSingleByte*/Punctuation* left alone: 全/半 and the punctuation"
Write-Host "marks read the same in Japanese."
