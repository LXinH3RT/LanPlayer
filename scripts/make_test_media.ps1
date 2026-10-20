# Generates the media fixtures used by the native smoke tests.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/make_test_media.ps1
#
# Needs the FFmpeg build downloaded by tool/fetch_deps.py (it ships ffmpeg.exe).
param(
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'build\media' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$ffmpeg = Get-ChildItem (Join-Path $root '.tools\ffmpeg') -Recurse -Filter 'ffmpeg.exe' -File |
    Select-Object -First 1
if (-not $ffmpeg) {
    throw 'ffmpeg.exe not found - run: python tool/fetch_deps.py ffmpeg'
}
$ff = $ffmpeg.FullName

# 1) plain clip: 640x360 h264 + 440 Hz sine, 6 s
Write-Host '== test.mp4 (video + audio)'
& $ff -hide_banner -loglevel error -y `
    -f lavfi -i 'testsrc2=size=640x360:rate=25' `
    -f lavfi -i 'sine=frequency=440:sample_rate=48000' `
    -t 6 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest `
    (Join-Path $OutDir 'test.mp4')
if ($LASTEXITCODE -ne 0) { throw 'ffmpeg failed for test.mp4' }

# 2) sidecar subtitle next to the same clip (auto-load path)
Write-Host '== clip.srt (external subtitle)'
$srt = @(
    '1', '00:00:00,500 --> 00:00:02,000', 'Hello LanPlayer (external SRT)', '',
    '2', '00:00:02,500 --> 00:00:04,500', 'Second line subtitle', '',
    '3', '00:00:04,600 --> 00:00:05,800', 'Third line', ''
) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $OutDir 'clip.srt'), $srt,
    (New-Object System.Text.UTF8Encoding($false)))
Copy-Item (Join-Path $OutDir 'test.mp4') (Join-Path $OutDir 'clip.mp4') -Force

# 3) muxed clip with an embedded subtitle track (embedded decode path)
Write-Host '== subbed.mkv (embedded subrip track)'
& $ff -hide_banner -loglevel error -y `
    -f lavfi -i 'testsrc2=size=640x360:rate=25' `
    -f lavfi -i 'sine=frequency=440:sample_rate=48000' `
    -i (Join-Path $OutDir 'clip.srt') `
    -t 6 -map 0:v -map 1:a -map 2:s `
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -c:s srt `
    (Join-Path $OutDir 'subbed.mkv')
if ($LASTEXITCODE -ne 0) { throw 'ffmpeg failed for subbed.mkv' }

# 4) solid red clip: the colour-order probe.
#
# The core hands out BGRA, Flutter's pixel-buffer texture reads RGBA, so the
# plugin must swap R and B.  A pure red frame makes a missed swap impossible to
# argue with: correct output is #FD0000, broken output is #0000FD (blue).  Only
# the flat centre is relied on, so a few pixels of YUV edge bleed are harmless.
#
# The clip is deliberately 60 s long: capturing a 4 s probe is a race against
# playback ending (the window then shows the ended state, not the frame), which
# made the screenshot evidence flaky.  A flat colour compresses to a few KiB, so
# the length costs nothing.  See docs/verification.md 3.14.
Write-Host '== colortest\red.mp4 (BGRA->RGBA probe)'
$colorDir = Join-Path $OutDir 'colortest'
New-Item -ItemType Directory -Force -Path $colorDir | Out-Null
& $ff -hide_banner -loglevel error -y `
    -f lavfi -i 'color=c=red:size=640x360:rate=25:duration=60' `
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p `
    (Join-Path $colorDir 'red.mp4')
if ($LASTEXITCODE -ne 0) { throw 'ffmpeg failed for colortest/red.mp4' }

Get-ChildItem $OutDir | Sort-Object Name | ForEach-Object {
    Write-Host ("   {0,-14} {1,8:N0} KiB" -f $_.Name, ($_.Length / 1KB))
}
Write-Host "`nrun: build\win-x64\lp_smoke_test.exe `"$OutDir\clip.mp4`" 6"
