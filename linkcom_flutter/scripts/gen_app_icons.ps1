# Generate app icons for Android (legacy mipmap + adaptive icon) and Windows (.ico)
# from public/logo.png.
# Usage: powershell -ExecutionPolicy Bypass -File scripts\gen_app_icons.ps1
#
# Outputs:
#   android/app/src/main/res/mipmap-<dpi>/ic_launcher.png        legacy icon (Android < 8)
#   android/app/src/main/res/drawable-<dpi>/ic_launcher_foreground.png  adaptive foreground
#   android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml   adaptive icon descriptor
#   android/app/src/main/res/values/ic_launcher_background.xml   adaptive background color
#   windows/runner/resources/app_icon.ico                        Windows exe/taskbar icon
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads .ps1 as ANSI when it has no BOM.
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$srcPath = Join-Path $root '..\public\logo.png'
$res = Join-Path $root 'android\app\src\main\res'
$icoPath = Join-Path $root 'windows\runner\resources\app_icon.ico'

# adaptive background color (white keeps the teal logo readable on every launcher mask)
$bgColor = '#FFFFFF'

if (-not (Test-Path $srcPath)) { throw "source icon not found: $srcPath" }
$src = [System.Drawing.Image]::FromFile($srcPath)
Write-Host "source: $srcPath ($($src.Width)x$($src.Height))"

# ---- trim fully transparent border, so the glyph is centered in the output ----
function Get-AlphaBox([System.Drawing.Bitmap]$bmp) {
  $minX = $bmp.Width; $minY = $bmp.Height; $maxX = -1; $maxY = -1
  for ($y = 0; $y -lt $bmp.Height; $y++) {
    for ($x = 0; $x -lt $bmp.Width; $x++) {
      if ($bmp.GetPixel($x, $y).A -gt 16) {
        if ($x -lt $minX) { $minX = $x }
        if ($x -gt $maxX) { $maxX = $x }
        if ($y -lt $minY) { $minY = $y }
        if ($y -gt $maxY) { $maxY = $y }
      }
    }
  }
  if ($maxX -lt 0) { return (New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)) }
  return (New-Object System.Drawing.Rectangle($minX, $minY, ($maxX - $minX + 1), ($maxY - $minY + 1)))
}

$full = New-Object System.Drawing.Bitmap($srcPath)
$box = Get-AlphaBox $full
$full.Dispose()
if ($box.Width -ne $src.Width -or $box.Height -ne $src.Height) {
  Write-Host "  trimmed transparent border -> $($box.Width)x$($box.Height)"
}
$art = $src.Clone($box, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)

# ---- render a size x size PNG where the glyph width is fillRatio * size ----
function New-IconPng([System.Drawing.Image]$img, [int]$size, [double]$fillRatio) {
  $bmp = New-Object System.Drawing.Bitmap($size, $size)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $w = [Math]::Max(1, [int][Math]::Round($size * $fillRatio))
  $h = [Math]::Max(1, [int][Math]::Round($w * $img.Height / $img.Width))
  if ($h -gt $size) { $h = $size; $w = [Math]::Max(1, [int][Math]::Round($h * $img.Width / $img.Height)) }
  $g.DrawImage($img, [int](($size - $w) / 2), [int](($size - $h) / 2), $w, $h)
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $bytes = $ms.ToArray()
  $g.Dispose(); $bmp.Dispose(); $ms.Dispose()
  return , $bytes
}

function Ensure-Dir([string]$p) { if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }

# ---- Android: legacy icons (glyph fills almost the whole square) ----
$dnMap = @{ 'mipmap-mdpi' = 48; 'mipmap-hdpi' = 72; 'mipmap-xhdpi' = 96; 'mipmap-xxhdpi' = 144; 'mipmap-xxxhdpi' = 192 }
foreach ($k in $dnMap.Keys) {
  $size = $dnMap[$k]
  $dir = Join-Path $res $k
  Ensure-Dir $dir
  [System.IO.File]::WriteAllBytes((Join-Path $dir 'ic_launcher.png'), (New-IconPng $art $size 0.96))
  Write-Host "  android $k/ic_launcher.png -> $size x $size"
}

# ---- Android: adaptive foreground (108dp canvas; keep the glyph inside the 66dp safe zone) ----
$fgMap = @{ 'drawable-mdpi' = 108; 'drawable-hdpi' = 162; 'drawable-xhdpi' = 216; 'drawable-xxhdpi' = 324; 'drawable-xxxhdpi' = 432 }
foreach ($k in $fgMap.Keys) {
  $size = $fgMap[$k]
  $dir = Join-Path $res $k
  Ensure-Dir $dir
  [System.IO.File]::WriteAllBytes((Join-Path $dir 'ic_launcher_foreground.png'), (New-IconPng $art $size 0.61))
  Write-Host "  android $k/ic_launcher_foreground.png -> $size x $size"
}

# ---- Android: adaptive icon descriptor + background color ----
$anydpi = Join-Path $res 'mipmap-anydpi-v26'
Ensure-Dir $anydpi
$adaptiveXml = @'
<?xml version="1.0" encoding="utf-8"?>
<!-- 自适应图标 (Android 8+): 前景为 drawable-*/ic_launcher_foreground.png, 背景为纯色。
     由 scripts/gen_app_icons.ps1 自动生成, 勿手动修改。 -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <!-- Android 13+ 主题图标: 系统按 alpha 重新着色 -->
    <monochrome android:drawable="@drawable/ic_launcher_foreground" />
</adaptive-icon>
'@
[System.IO.File]::WriteAllText((Join-Path $anydpi 'ic_launcher.xml'), $adaptiveXml, (New-Object System.Text.UTF8Encoding($false)))

$valuesDir = Join-Path $res 'values'
Ensure-Dir $valuesDir
$bgXml = @"
<?xml version="1.0" encoding="utf-8"?>
<!-- 自适应图标背景色 (由 scripts/gen_app_icons.ps1 生成, 勿手动修改) -->
<resources>
    <color name="ic_launcher_background">$bgColor</color>
</resources>
"@
[System.IO.File]::WriteAllText((Join-Path $valuesDir 'ic_launcher_background.xml'), $bgXml, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "  android adaptive icon -> mipmap-anydpi-v26/ic_launcher.xml (bg $bgColor)"

# ---- Windows .ico (multi-size, each entry is PNG data) ----
$sizes = @(16, 32, 48, 64, 128, 256)
$pngs = @()
foreach ($s in $sizes) { $pngs += , (New-IconPng $art $s 0.98) }

$fs = [System.IO.File]::Create($icoPath)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$sizes.Count)   # ICONDIR
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]; $data = $pngs[$i]
  $dim = if ($s -ge 256) { 0 } else { $s }   # 256 is stored as 0
  $bw.Write([Byte]$dim); $bw.Write([Byte]$dim)
  $bw.Write([Byte]0); $bw.Write([Byte]0)                                     # palette / reserved
  $bw.Write([UInt16]1); $bw.Write([UInt16]32)                                # 1 = PNG, 32bpp
  $bw.Write([UInt32]$data.Length); $bw.Write([UInt32]$offset)
  $offset += $data.Length
}
foreach ($d in $pngs) { $bw.Write($d) }
$bw.Close(); $fs.Close()
Write-Host "  windows -> $icoPath ($($sizes -join ', '))"

$art.Dispose(); $src.Dispose()
Write-Host 'done.'
