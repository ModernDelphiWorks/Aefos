<#
.SYNOPSIS
    Builds the Aefos IDE application icon (installer\lazarus\aefos-lazarus.ico)
    from the brand lockup PNG. Regenerate it when the brand art changes.

.DESCRIPTION
    WHY A GENERATOR AND NOT JUST A CHECKED-IN BINARY
    ------------------------------------------------
    The .ico IS checked in (the installer ships it and the IDE loads it), but a
    binary asset with no recipe rots: the next person who has to nudge the crop
    or add a size has to guess how the current one was made. This script is the
    recipe, and it is the only place the crop rectangle is written down.

    WHAT IT PRODUCES
    ----------------
    One multi-size .ico cropped to the Aefos speech-bubble MARK of
    source\chat\UI\branding\logo_about.png (the lockup's wordmark is unreadable
    below ~64 px, so the mark alone is what an icon can carry):

      16 .. 128  -> classic 32bpp BGRA DIB frames
      256        -> a PNG frame (the Vista+ convention; as a DIB it alone would
                    be 256 KB)

    ONLY 256 MAY BE A PNG, AND THAT IS NOT A STYLE CHOICE. Windows reads a PNG
    frame at ANY size, but the LCL does not: lcl\include\icon.inc:880 sniffs the
    PNG signature ONLY when the directory entry's width/height byte is 0 - which
    encodes exactly 256. A 128x128 PNG frame is therefore handed to the DIB
    reader, which reads the PNG header as a BITMAPINFOHEADER and dies with
    "Bitmap with unknown compression (-2147483648)". That matters because the
    running IDE loads this same file through the LCL
    (source\lazarus\ide\Aefos.Lazarus.AppIdentity.pas), and it is exactly what
    the first cut of this icon did - caught by
    the app-icon proof, which now reads every
    frame back and would fail again on the same mistake.

    The AND mask of every DIB frame is all zeroes: for 32bpp frames Windows uses
    the alpha channel, and a zero mask is the standard "fully opaque mask, alpha
    decides" encoding.

.PARAMETER SourcePng
    The brand lockup. Default source\chat\UI\branding\logo_about.png (420x420).

.PARAMETER OutFile
    Where the .ico goes. Default installer\lazarus\aefos-lazarus.ico.

.EXAMPLE
    pwsh -File scripts\build-aefos-icon.ps1
#>

[CmdletBinding()]
param(
    [string]$SourcePng,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepoRoot  = Split-Path -Parent $ScriptDir

if ([string]::IsNullOrWhiteSpace($SourcePng)) {
    $SourcePng = Join-Path $RepoRoot 'source\chat\UI\branding\logo_about.png'
}
if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $OutFile = Join-Path $RepoRoot 'installer\lazarus\aefos-lazarus.ico'
}

# The mark inside the 420x420 lockup: the speech bubble with the Aefos glyph and
# the three dots, without the "Aefos AI / CHAT" wordmark below it.
$CropX = 96
$CropY = 16
$CropW = 236
$CropH = 236

$Sizes = @(16, 24, 32, 48, 64, 128, 256)
# 256 and nothing below it - see the header: the LCL only looks for a PNG frame
# where the directory entry's size byte is 0, and that byte encodes 256 alone.
$PngFrom = 256

Add-Type -AssemblyName System.Drawing

<#
.SYNOPSIS
    The mark, redrawn at NxN with high-quality resampling straight from the
    full-resolution source (never from an already-downscaled step).
#>
function New-AefosIconFrame {
    param(
        [Parameter(Mandatory = $true)][System.Drawing.Image]$Source,
        [Parameter(Mandatory = $true)][int]$Size
    )
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $gfx.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $gfx.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $gfx.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $gfx.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $dst = New-Object System.Drawing.Rectangle(0, 0, $Size, $Size)
        $src = New-Object System.Drawing.Rectangle($CropX, $CropY, $CropW, $CropH)
        $gfx.DrawImage($Source, $dst, $src, [System.Drawing.GraphicsUnit]::Pixel)
    } finally {
        $gfx.Dispose()
    }
    return $bmp
}

<#
.SYNOPSIS
    One icon frame as a classic 32bpp DIB: BITMAPINFOHEADER (biHeight doubled),
    bottom-up BGRA rows, then an all-zero 1bpp AND mask.
#>
function Get-AefosIconDibBytes {
    param([Parameter(Mandatory = $true)][System.Drawing.Bitmap]$Bitmap)
    $w = $Bitmap.Width
    $h = $Bitmap.Height
    $maskStride = [int](([int](($w + 31) / 32)) * 4)
    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($stream)
    try {
        $writer.Write([UInt32]40)          # biSize
        $writer.Write([Int32]$w)           # biWidth
        $writer.Write([Int32]($h * 2))     # biHeight: XOR image + AND mask
        $writer.Write([UInt16]1)           # biPlanes
        $writer.Write([UInt16]32)          # biBitCount
        $writer.Write([UInt32]0)           # biCompression = BI_RGB
        $writer.Write([UInt32]($w * $h * 4 + $maskStride * $h))  # biSizeImage
        $writer.Write([Int32]0)            # biXPelsPerMeter
        $writer.Write([Int32]0)            # biYPelsPerMeter
        $writer.Write([UInt32]0)           # biClrUsed
        $writer.Write([UInt32]0)           # biClrImportant

        $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
        $data = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                                 [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $row = New-Object byte[] ($w * 4)
            for ($y = $h - 1; $y -ge 0; $y--) {
                $ptr = [IntPtr]::Add($data.Scan0, $y * $data.Stride)
                [System.Runtime.InteropServices.Marshal]::Copy($ptr, $row, 0, $row.Length)
                $writer.Write($row, 0, $row.Length)
            }
        } finally {
            $Bitmap.UnlockBits($data)
        }

        $maskRow = New-Object byte[] $maskStride
        for ($y = 0; $y -lt $h; $y++) { $writer.Write($maskRow, 0, $maskRow.Length) }
        $writer.Flush()
        return $stream.ToArray()
    } finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

<#
.SYNOPSIS
    One icon frame as a PNG (Vista+ frame encoding).
#>
function Get-AefosIconPngBytes {
    param([Parameter(Mandatory = $true)][System.Drawing.Bitmap]$Bitmap)
    $stream = New-Object System.IO.MemoryStream
    try {
        $Bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return $stream.ToArray()
    } finally {
        $stream.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $SourcePng)) { throw "Brand art not found: '$SourcePng'." }

$source = [System.Drawing.Image]::FromFile($SourcePng)
$frames = New-Object System.Collections.Generic.List[object]
try {
    foreach ($size in $Sizes) {
        $frame = New-AefosIconFrame -Source $source -Size $size
        try {
            if ($size -ge $PngFrom) { $bytes = Get-AefosIconPngBytes -Bitmap $frame }
            else                    { $bytes = Get-AefosIconDibBytes -Bitmap $frame }
        } finally {
            $frame.Dispose()
        }
        [void]$frames.Add([pscustomobject]@{ Size = $size; Bytes = $bytes })
    }
} finally {
    $source.Dispose()
}

$out    = New-Object System.IO.MemoryStream
$writer = New-Object System.IO.BinaryWriter($out)
try {
    $writer.Write([UInt16]0)               # idReserved
    $writer.Write([UInt16]1)               # idType = icon
    $writer.Write([UInt16]$frames.Count)   # idCount
    $offset = 6 + 16 * $frames.Count
    foreach ($frame in $frames) {
        # 256 is written as 0 in the single width/height byte.
        $dim = $frame.Size
        if ($dim -ge 256) { $dim = 0 }
        $writer.Write([byte]$dim)          # bWidth
        $writer.Write([byte]$dim)          # bHeight
        $writer.Write([byte]0)             # bColorCount (0 = truecolour)
        $writer.Write([byte]0)             # bReserved
        $writer.Write([UInt16]1)           # wPlanes
        $writer.Write([UInt16]32)          # wBitCount
        $writer.Write([UInt32]$frame.Bytes.Length)
        $writer.Write([UInt32]$offset)
        $offset += $frame.Bytes.Length
    }
    foreach ($frame in $frames) { $writer.Write($frame.Bytes, 0, $frame.Bytes.Length) }
    $writer.Flush()

    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllBytes($OutFile, $out.ToArray())
} finally {
    $writer.Dispose()
    $out.Dispose()
}

Write-Host ("Wrote {0} ({1} frames, {2} bytes)" -f $OutFile, $frames.Count, (Get-Item -LiteralPath $OutFile).Length)
