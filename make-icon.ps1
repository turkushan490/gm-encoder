#requires -Version 5.1
<#
  make-icon.ps1
  Generates docs/icon.ico from a programmatic render of the GM Encoder
  logo (no external image library needed - pure GDI+).
  Used by build-exe.ps1 to set the .exe icon and by the WPF Window.
#>

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Out  = Join-Path $Root 'docs\icon.ico'

Add-Type -AssemblyName System.Drawing

function New-LogoBitmap {
    param([int]$Size)
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.TextRenderingHint  = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

    # Rounded square background (dark blue gradient)
    $rect = New-Object System.Drawing.Rectangle 0, 0, $Size, $Size
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $r = [Math]::Max(1, [int]($Size * 0.18))   # corner radius
    $path.AddArc($rect.X,            $rect.Y,            $r*2, $r*2, 180, 90)
    $path.AddArc($rect.Right - $r*2, $rect.Y,            $r*2, $r*2, 270, 90)
    $path.AddArc($rect.Right - $r*2, $rect.Bottom - $r*2,$r*2, $r*2, 0,   90)
    $path.AddArc($rect.X,            $rect.Bottom - $r*2,$r*2, $r*2, 90,  90)
    $path.CloseFigure()

    $bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect,
        [System.Drawing.Color]::FromArgb(255, 30, 58, 138),
        [System.Drawing.Color]::FromArgb(255, 14, 43, 90),
        [System.Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal
    )
    $g.FillPath($bgBrush, $path)

    # "GM" wordmark
    $fontSize = [Math]::Max(8, [int]($Size * 0.42))
    $font = New-Object System.Drawing.Font 'Segoe UI', $fontSize, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $textBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 238, 244, 255))
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment      = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment  = [System.Drawing.StringAlignment]::Center
    # Slight upward offset to make space for progress bar
    $yOff = [single](-$Size * 0.07)
    $textRect = [System.Drawing.RectangleF]::new(0.0, $yOff, [single]$Size, [single]$Size)
    $g.DrawString('GM', $font, $textBrush, $textRect, $fmt)

    # Green progress bar at bottom
    $barY    = [int]($Size * 0.78)
    $barH    = [Math]::Max(2, [int]($Size * 0.08))
    $barPad  = [int]($Size * 0.14)
    $barWidth = $Size - $barPad*2
    $barRect = [System.Drawing.Rectangle]::new([int]$barPad, [int]$barY, [int]$barWidth, [int]$barH)

    # bar background
    $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 10, 20, 40))), $barRect)
    # filled portion (~70%)
    $filledRect = [System.Drawing.Rectangle]::new([int]$barPad, [int]$barY, [int]($barWidth * 0.7), [int]$barH)
    $barBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $filledRect,
        [System.Drawing.Color]::FromArgb(255, 34, 197, 94),
        [System.Drawing.Color]::FromArgb(255, 22, 163, 74),
        [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal
    )
    $g.FillRectangle($barBrush, $filledRect)

    $g.Dispose()
    return $bmp
}

# Generate multi-size ICO: 16, 32, 48, 64, 128, 256
$sizes = @(16, 32, 48, 64, 128, 256)
$pngStreams = @()
foreach ($s in $sizes) {
    $bmp = New-LogoBitmap -Size $s
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngStreams += ,@{ Size = $s; Bytes = $ms.ToArray() }
    $bmp.Dispose()
    $ms.Dispose()
}

# Build ICO file binary (multi-image format with PNG payloads)
$fs = [System.IO.File]::Create($Out)
$bw = New-Object System.IO.BinaryWriter $fs
# ICO header
$bw.Write([uint16]0)                # reserved
$bw.Write([uint16]1)                # type: 1 = icon
$bw.Write([uint16]$pngStreams.Count) # number of images

# Calculate where image data starts (header 6 + 16 per directory entry)
$dataOffset = 6 + ($pngStreams.Count * 16)

# Directory entries
foreach ($img in $pngStreams) {
    $sizeByte = if ($img.Size -ge 256) { [byte]0 } else { [byte]$img.Size }
    $bw.Write([byte]$sizeByte)          # width  (0 = 256)
    $bw.Write([byte]$sizeByte)          # height (0 = 256)
    $bw.Write([byte]0)                  # color palette (0 = no palette)
    $bw.Write([byte]0)                  # reserved
    $bw.Write([uint16]1)                # color planes
    $bw.Write([uint16]32)               # bits per pixel
    $bw.Write([uint32]$img.Bytes.Length) # image size in bytes
    $bw.Write([uint32]$dataOffset)      # offset in file
    $dataOffset += $img.Bytes.Length
}
# Image data
foreach ($img in $pngStreams) {
    $bw.Write($img.Bytes)
}
$bw.Close()
$fs.Close()

$icoSize = [Math]::Round((Get-Item $Out).Length / 1KB, 1)
Write-Host "[OK] $Out ($icoSize KB, $($pngStreams.Count) sizes: $($sizes -join ','))"
