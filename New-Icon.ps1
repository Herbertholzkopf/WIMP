<#
 Erzeugt aus einer Bilddatei (PNG, JPG, BMP) eine Windows-Icon-Datei (.ico)
 mit allen üblichen Größen - genau das, was PS2EXE für -iconFile braucht.

 Aufruf:
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\New-Icon.ps1 -Source .\logo.png

 Hinweis: Am besten ein quadratisches Bild mit mindestens 256x256 Pixeln
 verwenden. Nicht quadratische Bilder werden mittig auf ein quadratisches,
 transparentes Feld gelegt.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [string]$Destination,
    [int[]]$Sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$src = (Resolve-Path -LiteralPath $Source).Path
if (-not $Destination) { $Destination = [System.IO.Path]::ChangeExtension($src, '.ico') }

$img = [System.Drawing.Image]::FromFile($src)
try {
    # Jede Größe als PNG in den Speicher rendern (ICO ab Vista erlaubt PNG-Daten)
    $blobs = New-Object System.Collections.Generic.List[byte[]]
    foreach ($s in ($Sizes | Sort-Object -Unique)) {
        $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.Clear([System.Drawing.Color]::Transparent)

            # Seitenverhältnis erhalten, mittig einpassen
            $scale = [math]::Min($s / $img.Width, $s / $img.Height)
            $w = [int][math]::Round($img.Width  * $scale)
            $h = [int][math]::Round($img.Height * $scale)
            $g.DrawImage($img, [int](($s - $w) / 2), [int](($s - $h) / 2), $w, $h)
        } finally { $g.Dispose() }

        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $blobs.Add($ms.ToArray())
        $ms.Dispose(); $bmp.Dispose()
    }

    # ICO zusammensetzen: Kopf (6 Byte) + je Bild ein Verzeichniseintrag (16 Byte)
    $fs = [System.IO.File]::Create($Destination)
    $bw = New-Object System.IO.BinaryWriter($fs)
    try {
        $sorted = @($Sizes | Sort-Object -Unique)
        $bw.Write([uint16]0)                  # reserviert
        $bw.Write([uint16]1)                  # Typ 1 = Icon
        $bw.Write([uint16]$blobs.Count)

        $offset = 6 + (16 * $blobs.Count)
        for ($i = 0; $i -lt $blobs.Count; $i++) {
            $dim = $sorted[$i]
            $bw.Write([byte]$(if ($dim -ge 256) { 0 } else { $dim }))   # Breite (0 = 256)
            $bw.Write([byte]$(if ($dim -ge 256) { 0 } else { $dim }))   # Höhe
            $bw.Write([byte]0)                # Farbtabelle
            $bw.Write([byte]0)                # reserviert
            $bw.Write([uint16]1)              # Ebenen
            $bw.Write([uint16]32)             # Bit pro Pixel
            $bw.Write([uint32]$blobs[$i].Length)
            $bw.Write([uint32]$offset)
            $offset += $blobs[$i].Length
        }
        foreach ($b in $blobs) { $bw.Write($b) }
    } finally { $bw.Dispose(); $fs.Dispose() }
} finally { $img.Dispose() }

Write-Host "Icon geschrieben: $Destination ($([math]::Round((Get-Item $Destination).Length / 1KB, 1)) KB, $($Sizes.Count) Größen)"
