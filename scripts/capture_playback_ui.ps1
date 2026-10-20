# Captures the player page WITH the transport UI visible, and measures where the
# chrome actually landed.
#
# Why not just capture_screen.ps1: the transport UI hides itself after 2 s of
# pointer idle, so a plain "wait then grab" always photographs a bare picture.
# This script parks the system cursor inside the window first (which both shows
# the UI and keeps it shown for another 2 s) and only then grabs the screen.
#
# Why whole-screen: on a scaled display the Flutter view is composited at a
# different offset than GetWindowRect reports, so a window-rect CopyFromScreen
# can miss the client area entirely. The client rect from ClientToScreen is the
# truth, and the picture is cropped from a full-desktop grab.
#
#   powershell -File scripts\capture_playback_ui.ps1 -Exe <lanplayer.exe> -Open <video>
#
# Prints the measured bright-pixel counts that the layout assertions use.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Open = '',
    [string]$StateDir = '',
    [string]$LogDir = '',
    [string]$Out = '',
    [int]$WarmupMs = 12000
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$code = @"
using System;
using System.Runtime.InteropServices;

public class UiCap {
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
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    // Required: without DPI awareness ClientToScreen reports virtualised (logical)
    // pixels while CopyFromScreen captures physical ones, so the crop lands offset
    // from the window -- the exact bug that made earlier screenshots useless.
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    public static IntPtr FindMainWindow(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate (IntPtr h, IntPtr p) {
            uint wpid;
            GetWindowThreadProcessId(h, out wpid);
            if (wpid == pid && IsWindowVisible(h) && GetWindowTextLength(h) > 0) {
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
[void][UiCap]::SetProcessDPIAware()

if ($LogDir -eq '') { $LogDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'build\verify-ui' }
if ($StateDir -eq '') { $StateDir = Join-Path $LogDir 'state' }
New-Item -ItemType Directory -Force -Path $LogDir, $StateDir | Out-Null
if ($Out -eq '') { $Out = Join-Path $LogDir 'player-ui.png' }
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

$hwnd = [UiCap]::FindMainWindow([uint32]$proc.Id)
if ($hwnd -eq [IntPtr]::Zero) {
    Write-Output '!! no visible window found'
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    exit 1
}
$view = [UiCap]::FindView($hwnd)

[void][UiCap]::ShowWindow($hwnd, 9)
[void][UiCap]::BringWindowToTop($hwnd)
[void][UiCap]::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds 800

$cr = New-Object UiCap+RECT
[UiCap]::GetClientRect($view, [ref]$cr) | Out-Null
$cw = $cr.Right - $cr.Left
$ch = $cr.Bottom - $cr.Top
$origin = New-Object UiCap+POINT
$origin.X = 0; $origin.Y = 0
[UiCap]::ClientToScreen($view, [ref]$origin) | Out-Null
Write-Output ("window: hwnd=0x{0:X} view=0x{1:X} client={2}x{3} at {4},{5}" -f `
    $hwnd.ToInt64(), $view.ToInt64(), $cw, $ch, $origin.X, $origin.Y)

# Jiggle the cursor: this is what makes the transport UI appear and start its 2 s
# countdown. A single SetCursorPos is not enough -- if the pointer already sits at
# that exact spot Windows emits no WM_MOUSEMOVE and the UI stays hidden, which is
# why an earlier version of this script captured a bare picture.
$cx = $origin.X + [int]($cw / 2)
$cy = $origin.Y + [int]($ch / 2)
[void][UiCap]::SetCursorPos($cx + 40, $cy + 30)
Start-Sleep -Milliseconds 80
for ($i = 0; $i -lt 6; $i++) {
    [void][UiCap]::SetCursorPos($cx - $i * 6, $cy - $i * 4)
    Start-Sleep -Milliseconds 60
}
Start-Sleep -Milliseconds 150

$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$screen = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$g = [System.Drawing.Graphics]::FromImage($screen)
$g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0,
    (New-Object System.Drawing.Size $bounds.Width, $bounds.Height))
$g.Dispose()

# Keep the untouched desktop grab as well. When the crop lands in the wrong place,
# this file is the only way to see where the window really was -- the crop cannot
# tell you it is wrong, it just looks empty.
$full = [System.IO.Path]::ChangeExtension($Out, '.full.png')
$screen.Save($full, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Output ("screen: {0}x{1} saved to {2}" -f $bounds.Width, $bounds.Height, $full)

$rect = New-Object System.Drawing.Rectangle $origin.X, $origin.Y, $cw, $ch
$crop = $screen.Clone($rect, $screen.PixelFormat)
$screen.Dispose()
$crop.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Output ("captured: {0} ({1}x{2})" -f $Out, $crop.Width, $crop.Height)

# Count bright pixels (the icons and labels are near-white on dark scrims) in
# named regions, using LockBits -- GetPixel is ~100x slower and this walks every
# pixel of several regions.
$bmpData = $crop.LockBits((New-Object System.Drawing.Rectangle 0, 0, $crop.Width, $crop.Height),
    [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$stride = $bmpData.Stride
$buf = New-Object byte[] ($stride * $crop.Height)
[System.Runtime.InteropServices.Marshal]::Copy($bmpData.Scan0, $buf, 0, $buf.Length)
$crop.UnlockBits($bmpData)

function Count-Bright([int]$x0, [int]$y0, [int]$w, [int]$h, [int]$threshold = 200) {
    $hit = 0
    for ($y = $y0; $y -lt ($y0 + $h); $y++) {
        if ($y -lt 0 -or $y -ge $crop.Height) { continue }
        $row = $y * $stride
        for ($x = $x0; $x -lt ($x0 + $w); $x++) {
            if ($x -lt 0 -or $x -ge $crop.Width) { continue }
            $i = $row + $x * 4
            if ($buf[$i] -gt $threshold -and $buf[$i + 1] -gt $threshold -and $buf[$i + 2] -gt $threshold) {
                $hit++
            }
        }
    }
    return $hit
}

# Regions are relative to the client rect and scale with it, so this holds for
# any window size the runner happens to use.
$bw = [int]($cw * 0.14)   # a strip wide enough for one icon button
$bh = [int]($ch * 0.13)   # the top bar
$topLeft = Count-Bright 0 0 $bw $bh
$topRight = Count-Bright ($cw - $bw) 0 $bw $bh
$midLeft = Count-Bright 0 ([int]($ch * 0.42)) $bw ([int]($ch * 0.16))
$botRow = Count-Bright 0 ($ch - [int]($ch * 0.20)) $cw ([int]($ch * 0.20))

Write-Output ("bright pixels top-left={0} top-right={1} mid-left={2} bottom-row={3}" -f `
    $topLeft, $topRight, $midLeft, $botRow)

Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300
Write-Output '---- stdout (last 6) ----'
Get-Content $outLog -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 6
Write-Output '---- stderr (last 4) ----'
Get-Content $errLog -ErrorAction SilentlyContinue | Select-Object -Last 4
