# Proves the player page's "show controls on mouse move, hide after 2 s idle" behaviour.
#
# Why a dedicated script: Flutter offers no CLI way to inject pointer events, and
# the player page cannot be proven by screen capture (once the external video
# texture is registered, CopyFromScreen reads black -- see docs/verification.md).
# So the app prints `LanPlayer controls: shown|hidden` whenever the transport UI
# really appears or disappears, and this script moves the pointer over the window
# and asserts on those paired lines in stdout.
#
# Pointer input goes through PostMessage(WM_MOUSEMOVE) delivered to the Flutter
# view (a child of the top-level frame), not SendInput: this machine cannot
# reliably take the foreground of the desktop session.
#
#   powershell -File scripts\hover_probe.ps1 -Exe <lanplayer.exe> -Open <video>
#
# Exit codes: 0 ok, 1 setup problem, 2 assertion failed.
#
# NOTE: keep this file pure ASCII. Windows PowerShell reads a BOM-less script in
# the ANSI code page, so UTF-8 Chinese text here turns into mojibake and the
# parser dies on the first multi-byte character.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Open = '',
    [string]$StateDir = '',
    [string]$LogDir = '',
    [int]$WarmupMs = 11000,
    [int]$IdleMs = 3500,
    [string[]]$Points = @('0.5,0.5', '0.6,0.4', '0.4,0.6', '0.5,0.3')
)

$ErrorActionPreference = 'Continue'

$code = @"
using System;
using System.Runtime.InteropServices;

public class HoverWin {
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);

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

    // Flutter's message handler lives in a child window of the frame, and pointer
    // coordinates are relative to that child's client area.
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

$WM_MOUSEMOVE = 0x0200

if ($LogDir -eq '') { $LogDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'build\verify-hover' }
if ($StateDir -eq '') { $StateDir = Join-Path $LogDir 'state' }
New-Item -ItemType Directory -Force -Path $LogDir, $StateDir | Out-Null
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

$hwnd = [HoverWin]::FindMainWindow([uint32]$proc.Id)
if ($hwnd -eq [IntPtr]::Zero) {
    Write-Output '!! no visible window found'
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    exit 1
}
$view = [HoverWin]::FindView($hwnd)
$cr = New-Object HoverWin+RECT
[HoverWin]::GetClientRect($view, [ref]$cr) | Out-Null
$cw = $cr.Right - $cr.Left
$ch = $cr.Bottom - $cr.Top
Write-Output ("window: hwnd=0x{0:X} view=0x{1:X} client={2}x{3}" -f `
    $hwnd.ToInt64(), $view.ToInt64(), $cw, $ch)

# The Flutter view only receives WM_MOUSEMOVE when the pointer is genuinely over
# it: the engine asks Win32 for the cursor position rather than trusting lParam,
# and a posted message alone never sets Flutter's own _mouseTracker "inside"
# state. So raise the window and actually move the system cursor.
[void][HoverWin]::ShowWindow($hwnd, 9)
[void][HoverWin]::BringWindowToTop($hwnd)
[void][HoverWin]::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds 700

function Get-Log([string]$pattern) {
    if (-not (Test-Path $outLog)) { return @() }
    return @(Get-Content $outLog -Encoding UTF8 -ErrorAction SilentlyContinue |
        Select-String -Pattern $pattern | ForEach-Object { $_.Line })
}

# Park the cursor well outside the window so the first real move is a genuine
# enter: otherwise "already inside, moved by 0 px" produces no event at all.
function Park-Cursor {
    [void][HoverWin]::SetCursorPos(2, 2)
    Start-Sleep -Milliseconds 250
}

function Send-Move([double]$fx, [double]$fy) {
    $pt = New-Object HoverWin+POINT
    $pt.X = [int]($cw * $fx)
    $pt.Y = [int]($ch * $fy)
    [HoverWin]::ClientToScreen($view, [ref]$pt) | Out-Null
    [void][HoverWin]::SetCursorPos($pt.X, $pt.Y)
    $cur = New-Object HoverWin+POINT
    [HoverWin]::GetCursorPos([ref]$cur) | Out-Null
    Write-Output ("  cursor -> {0},{1} (wanted {2},{3})" -f $cur.X, $cur.Y, $pt.X, $pt.Y)
}

Write-Output '--- phase 1: sit still, the transport UI should hide on its own ---'
$t0 = Get-Date
while (((Get-Date) - $t0).TotalMilliseconds -lt $IdleMs) { Start-Sleep -Milliseconds 250 }
$idleLines = @(Get-Log 'controls: hidden')
Write-Output ("after {0} ms idle: hidden count = {1}" -f $IdleMs, $idleLines.Count)
foreach ($l in $idleLines) { Write-Output "  $l" }

Write-Output '--- phase 2: move the pointer, the UI should come back ---'
$before = @(Get-Log 'controls: shown').Count
Park-Cursor
foreach ($pt in $Points) {
    $parts = $pt -split ','
    Send-Move ([double]$parts[0]) ([double]$parts[1])
    Start-Sleep -Milliseconds 400
}
Start-Sleep -Milliseconds 600
$newShown = @(Get-Log 'controls: shown').Count - $before
Write-Output ("{0} moves produced {1} new 'shown' lines (want >= 1)" -f $Points.Count, $newShown)

Write-Output '--- phase 3: sit still again, it should hide again ---'
$hiddenBefore = @(Get-Log 'controls: hidden').Count
Start-Sleep -Milliseconds $IdleMs
$hiddenAfter = @(Get-Log 'controls: hidden').Count
Write-Output ("another {0} ms idle produced {1} new 'hidden' lines (want >= 1)" -f `
    $IdleMs, ($hiddenAfter - $hiddenBefore))

Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

Write-Output '---- full controls log ----'
foreach ($l in Get-Log 'controls:') { Write-Output $l }
Write-Output '---- stderr ----'
Get-Content $errLog -ErrorAction SilentlyContinue

$ok = ($idleLines.Count -ge 1) -and ($newShown -ge 1) -and (($hiddenAfter - $hiddenBefore) -ge 1)
if ($ok) { Write-Output 'hover probe: OK' } else { Write-Output 'hover probe: FAILED'; exit 2 }
