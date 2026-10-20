# Sends synthetic keystrokes to a running LanPlayer window.
#
# Why this exists: the player screen's keyboard shortcuts (space, arrows, F, M,
# S, Esc) can only be proven by driving the real Win32 window -- Flutter offers
# no CLI way to inject key events.  The app prints one "LanPlayer key: <label>"
# line per handled shortcut, so the captured stdout is the assertion.
#
# PostMessage is used instead of SendInput because the environment cannot reliably
# take the foreground focus of the desktop session.  Keys are posted to the
# focused child window (the Flutter view), not the top-level frame, because that
# is where Flutter's message handler lives.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Open = '',
    [string]$StateDir = '',
    [string]$LogDir = '',
    [string[]]$Keys = @('Space', 'Right', 'Right', 'F', 'F', 'M', 'S', 'Escape'),
    [int]$WarmupMs = 9000,
    [int]$GapMs = 800,
    [string]$Out = ''
)

$ErrorActionPreference = 'Continue'

# `-File script.ps1 -Keys a,b,c` hands PowerShell one comma-joined string rather
# than an array, so split it back into individual key names.
$Keys = @($Keys | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' })

$code = @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class KeyWin {
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO gti);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);

    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO {
        public int cbSize; public int flags;
        public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
        public RECT rcCaret;
    }

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

    // The Flutter view is a child of the frame; keys must go to whatever the
    // thread considers focused, falling back to the frame itself.
    public static IntPtr FocusWindow(IntPtr frame) {
        uint pid;
        uint tid = GetWindowThreadProcessId(frame, out pid);
        GUITHREADINFO gti = new GUITHREADINFO();
        gti.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
        if (GetGUIThreadInfo(tid, ref gti) && gti.hwndFocus != IntPtr.Zero) {
            return gti.hwndFocus;
        }
        return frame;
    }

    public static bool Capture(IntPtr h, string path) {
        RECT r;
        if (!GetWindowRect(h, out r)) return false;
        int w = r.Right - r.Left, ht = r.Bottom - r.Top;
        if (w <= 0 || ht <= 0) return false;
        using (Bitmap bmp = new Bitmap(w, ht, PixelFormat.Format32bppArgb)) {
            using (Graphics g = Graphics.FromImage(bmp)) {
                IntPtr dc = g.GetHdc();
                bool ok = PrintWindow(h, dc, 2);
                g.ReleaseHdc(dc);
                if (!ok) return false;
            }
            bmp.Save(path, ImageFormat.Png);
        }
        return true;
    }
}
"@

Add-Type -TypeDefinition $code -ReferencedAssemblies System.Drawing

$VK = @{
    Space = 0x20; Left = 0x25; Up = 0x26; Right = 0x27; Down = 0x28
    Escape = 0x1B; F = 0x46; M = 0x4D; K = 0x4B; S = 0x53; D = 0x44
}
$WM_KEYDOWN = 0x0100
$WM_KEYUP = 0x0101
$WM_SYSKEYDOWN = 0x0104
$WM_SYSKEYUP = 0x0105

if ($LogDir -eq '') { $LogDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'build\media\keys' }
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

$hwnd = [KeyWin]::FindMainWindow([uint32]$proc.Id)
if ($hwnd -eq [IntPtr]::Zero) {
    Write-Output '!! no visible window found'
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    exit 1
}
$focus = [KeyWin]::FocusWindow($hwnd)
Write-Output ("window: hwnd=0x{0:X} focus=0x{1:X}" -f $hwnd.ToInt64(), $focus.ToInt64())

# Printed after every key that can change the geometry so the log proves the
# window really went fullscreen and came back (F toggles, Escape leaves it).
function Show-Rect([string]$when) {
    $r = New-Object KeyWin+RECT
    if ([KeyWin]::GetWindowRect($hwnd, [ref]$r)) {
        $w = $r.Right - $r.Left
        $h = $r.Bottom - $r.Top
        Write-Output ("rect[$when]: {0}x{1} at {2},{3}" -f $w, $h, $r.Left, $r.Top)
    }
}

Show-Rect 'start'

foreach ($name in $Keys) {
    # NOTE: PowerShell variables are case-insensitive, so the per-key code must
    # NOT be called $vk -- that would overwrite the $VK map built above.
    if (-not $VK.ContainsKey($name)) { Write-Output "?? unknown key $name"; continue }
    $vkCode = [int]$VK[$name]
    $isAlt = ($name -eq 'F')
    $down = if ($isAlt) { $WM_SYSKEYDOWN } else { $WM_KEYDOWN }
    $up = if ($isAlt) { $WM_SYSKEYUP } else { $WM_KEYUP }
    [void][KeyWin]::PostMessage($focus, $down, [IntPtr]$vkCode, [IntPtr]0x00000001)
    Start-Sleep -Milliseconds 50
    [void][KeyWin]::PostMessage($focus, $up, [IntPtr]$vkCode, [IntPtr]0xC0000001)
    Write-Output "sent: $name"
    Start-Sleep -Milliseconds $GapMs
    if ($name -eq 'F' -or $name -eq 'Escape') { Show-Rect $name }
}

if ($Out -ne '') {
    if ([KeyWin]::Capture($hwnd, $Out)) { Write-Output "captured: $Out" }
    else { Write-Output '!! PrintWindow failed' }
}

Start-Sleep -Milliseconds 400
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300
Write-Output '---- stdout ----'
Get-Content $outLog -ErrorAction SilentlyContinue
Write-Output '---- stderr ----'
Get-Content $errLog -ErrorAction SilentlyContinue
