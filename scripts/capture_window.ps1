# Launches the Flutter desktop app, captures its window to a PNG, closes it.
# Used as evidence that the MSVC-built runner actually renders the UI.
param(
    [string]$Exe = 'D:\repo\LanPlayer\build\msvc-chain\lanplayer.exe',
    [string]$Out = 'D:\repo\LanPlayer\build\msvc-chain\window.png',
    [int]$WaitMs = 7000
)

$ErrorActionPreference = 'Stop'

$code = @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class WinCap {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);

    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

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

    public static bool Capture(IntPtr h, string path) {
        RECT r;
        if (!GetWindowRect(h, out r)) return false;
        int w = r.Right - r.Left, ht = r.Bottom - r.Top;
        if (w <= 0 || ht <= 0) return false;
        using (Bitmap bmp = new Bitmap(w, ht, PixelFormat.Format32bppArgb)) {
            using (Graphics g = Graphics.FromImage(bmp)) {
                IntPtr dc = g.GetHdc();
                bool ok = PrintWindow(h, dc, 2 /* PW_RENDERFULLCONTENT */);
                g.ReleaseHdc(dc);
                if (!ok) return false;
            }
            bmp.Save(path, ImageFormat.Png);
        }
        return true;
    }
}
"@

Add-Type -TypeDefinition $code -ReferencedAssemblies System.Drawing, System.Windows.Forms

$proc = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru
Start-Sleep -Milliseconds $WaitMs

$hwnd = [WinCap]::FindMainWindow([uint32]$proc.Id)
if ($hwnd -eq [IntPtr]::Zero) {
    Write-Host 'no visible window found'
    Stop-Process -Id $proc.Id -Force
    exit 1
}
$title = New-Object System.Text.StringBuilder 512
[void][WinCap]::GetWindowText($hwnd, $title, 512)
Write-Host ("window: hwnd=0x{0:X} title='{1}'" -f $hwnd.ToInt64(), $title.ToString())

if ([WinCap]::Capture($hwnd, $Out)) {
    Write-Host "captured: $Out"
    $rc = 0
} else {
    Write-Host 'PrintWindow failed'
    $rc = 2
}
Stop-Process -Id $proc.Id -Force
exit $rc
