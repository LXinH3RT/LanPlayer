# Capture the audio/subtitle track sheet, to prove the player lists every track
# inside the file (the user's report was "only one track, and the audio sheet was
# titled 'subtitles'").
#
# Why a dedicated script: capture_playback_ui.ps1 only photographs the transport
# bar. Opening the sheet needs a real click, and the transport bar hides itself
# after 2 s of pointer idle -- so this script nudges the pointer, clicks the
# button, then grabs the screen.
#
#   powershell -File scripts\capture_track_sheet.ps1 -Exe <lanplayer.exe> `
#       -Open <video> [-Button audio|subtitle] -Out <png>
#
# -Button settings shoots the settings page instead (no -Open, add -Scroll N to
# reach the language dropdowns).
#
# Button positions are computed from the client rect, so a different window size
# does not need new magic numbers.
#
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 decodes a .ps1 without
# a UTF-8 BOM as ANSI, and the resulting mojibake eats the statement that follows
# the comment (a session was lost to exactly that: `$btnY` silently came out
# empty and the click landed at y=0).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Open = '',
    [string]$StateDir = '',
    [string]$LogDir = '',
    [string]$Out = '',
    [ValidateSet('audio', 'subtitle', 'settings')][string]$Button = 'audio',
    # Only used by -Button settings: the language dropdowns sit below the fold, so
    # the shot has to scroll first. Wheel notches, each one ~3 lines.
    [int]$Scroll = 0,
    [int]$WarmupMs = 12000,
    # Explicit click point in client coordinates. The ratio defaults below were
    # measured on one window size; pass these to hit another one precisely.
    [int]$BtnX = 0,
    [int]$BtnY = 0
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$code = @"
using System;
using System.Runtime.InteropServices;

public class SheetCap {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, int d, UIntPtr e);

    public const uint LEFTDOWN = 0x0002;
    public const uint LEFTUP = 0x0004;
    public const uint WHEEL = 0x0800;

    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    public static IntPtr FindMainWindow(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate (IntPtr h, IntPtr p) {
            uint wpid;
            GetWindowThreadProcessId(h, out wpid);
            if (wpid == pid && IsWindowVisible(h)) {
                RECT r;
                GetWindowRect(h, out r);
                if ((r.Right - r.Left) > 200 && (r.Bottom - r.Top) > 200) { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static IntPtr FindView(IntPtr frame) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(frame, delegate (IntPtr h, IntPtr p) {
            if (IsWindowVisible(h)) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found == IntPtr.Zero ? frame : found;
    }
}
"@

Add-Type -TypeDefinition $code
[void][SheetCap]::SetProcessDPIAware()

if ($LogDir -eq '') { $LogDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'build\verify-track-sheet' }
if ($StateDir -eq '') { $StateDir = Join-Path $LogDir 'state' }
New-Item -ItemType Directory -Force -Path $LogDir, $StateDir | Out-Null
if ($Out -eq '') { $Out = Join-Path $LogDir ("track-$Button.png") }
# GDI+'s Save does not create directories; when the parent is missing it reports
# "A generic error occurred in GDI+", which says nothing about the real cause.
New-Item -ItemType Directory -Force -Path (Split-Path $Out -Parent) | Out-Null
$outLog = Join-Path $LogDir 'stdout.txt'
$errLog = Join-Path $LogDir 'stderr.txt'

$env:LANPLAYER_STATE_DIR = (Resolve-Path $StateDir).Path
if ($Open -ne '') { $env:LANPLAYER_OPEN = $Open }
else { Remove-Item Env:\LANPLAYER_OPEN -ErrorAction SilentlyContinue }

$proc = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru `
    -RedirectStandardOutput $outLog -RedirectStandardError $errLog
Start-Sleep -Milliseconds $WarmupMs
$proc.Refresh()
if ($proc.HasExited) {
    Write-Output "!! app exited early (code $($proc.ExitCode))"
    Get-Content $outLog -ErrorAction SilentlyContinue
    Get-Content $errLog -ErrorAction SilentlyContinue
    exit 1
}

$hwnd = [SheetCap]::FindMainWindow([uint32]$proc.Id)
if ($hwnd -eq [IntPtr]::Zero) {
    Write-Output '!! no visible window found'
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    exit 1
}
$view = [SheetCap]::FindView($hwnd)

[void][SheetCap]::ShowWindow($hwnd, 9)
[void][SheetCap]::BringWindowToTop($hwnd)
[void][SheetCap]::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds 800

$cr = New-Object SheetCap+RECT
[void][SheetCap]::GetClientRect($view, [ref]$cr)
$cw = $cr.Right - $cr.Left
$chh = $cr.Bottom - $cr.Top
$origin = New-Object SheetCap+POINT
$origin.X = 0; $origin.Y = 0
[void][SheetCap]::ClientToScreen($view, [ref]$origin)
Write-Output ("window: hwnd=0x{0:X} client={1}x{2} at {3},{4}" -f $hwnd.ToInt64(), $cw, $chh, $origin.X, $origin.Y)

function Move-To([int]$x, [int]$y) {
    [void][SheetCap]::SetCursorPos($origin.X + $x, $origin.Y + $y)
    Start-Sleep -Milliseconds 120
}
function Click-Here([int]$x, [int]$y) {
    Move-To $x $y
    Start-Sleep -Milliseconds 200
    [void][SheetCap]::mouse_event([SheetCap]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 70
    [void][SheetCap]::mouse_event([SheetCap]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
}

# Nudge the pointer so the transport bar appears and restarts its 2 s timer.
$midX = [int]($cw / 2)
$midY = [int]($chh / 2)
Move-To ($midX + 40) ($midY + 30)
Move-To $midX $midY
Start-Sleep -Milliseconds 400

# Bottom icon row: speed 1.0x, picture, subtitles, audio, volume. Measured on a
# 2216x1196 client by scanning the screenshot for the glyph clusters, rows
# 1137..1165 (center y=1151): picture icon x=955, subtitle x=1101, audio x=1247,
# volume x=1395. The icon takes the tap, not the label, so aim at the glyph.
# Beware the labels: "字幕" text sits at x=1131..1191, one column right of the
# audio icon, and clicking it opens the subtitle sheet instead.
if ($Button -eq 'settings') {
    # Home screen only: the settings icon is the last AppBar action, top right.
    $btnX = [int]($cw - 42)
    $btnY = [int]($chh * 0.043)
} else {
    $btnY = [int]($chh * 0.962)
    switch ($Button) {
        'audio'    { $btnX = [int]($cw * 0.5627) }
        'subtitle' { $btnX = [int]($cw * 0.4968) }
    }
}
if ($BtnX -gt 0) { $btnX = $BtnX }
if ($BtnY -gt 0) { $btnY = $BtnY }

# First click only activates the window: Windows spends the first click sent to a
# background window on activation, so Flutter never sees a tap.
Click-Here ([int]($cw * 0.5)) ([int]($chh * 0.62))
Start-Sleep -Milliseconds 700

Click-Here $btnX $btnY
Write-Output "clicked $Button at client ($btnX,$btnY)"
Start-Sleep -Milliseconds 1800

# Settings is a long ListView and the language tiles live below the fold, so the
# shot needs a scroll. Sent as wheel notches at the centre of the list.
if ($Scroll -gt 0) {
    Move-To ([int]($cw * 0.5)) ([int]($chh * 0.6))
    for ($i = 0; $i -lt $Scroll; $i++) {
        [void][SheetCap]::mouse_event([SheetCap]::WHEEL, 0, 0, 0xFFFFFB90, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 120
    }
    Start-Sleep -Milliseconds 700
    Write-Output "scrolled $Scroll notches"
}

# Grab the whole desktop and crop to the client rect: on a scaled display the
# Flutter view is composited at a different offset than GetWindowRect reports.
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$fullBmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$g = [System.Drawing.Graphics]::FromImage($fullBmp)
$g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0,
    (New-Object System.Drawing.Size $bounds.Width, $bounds.Height))
$g.Dispose()

# Keep the untouched desktop grab: when a crop lands in the wrong place this file
# is the only way to see where the window really was.
$fullPath = [System.IO.Path]::ChangeExtension($Out, '.full.png')
$fullBmp.Save($fullPath, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Output ("screen: {0}x{1} saved to {2}" -f $bounds.Width, $bounds.Height, $fullPath)

$rect = New-Object System.Drawing.Rectangle $origin.X, $origin.Y, $cw, $chh
$crop = $fullBmp.Clone($rect, $fullBmp.PixelFormat)
$fullBmp.Dispose()
$crop.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Output ("captured: {0} ({1}x{2})" -f $Out, $crop.Width, $crop.Height)
$crop.Dispose()

Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300
Write-Output '---- stdout (last 8) ----'
Get-Content $outLog -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 8
