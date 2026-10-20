# Launches the Flutter desktop app with stdout/stderr redirected to files,
# waits, captures its window to a PNG, then closes it.
#
# Differs from capture_window.ps1 (which discards output): this one keeps the
# Dart `print` output so a browse/open failure is visible in the evidence.
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$LogDir = '',
    [int]$WaitMs = 12000
)

$ErrorActionPreference = 'Stop'

if (-not $LogDir) { $LogDir = Split-Path $Out }
if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
}
$stdout = Join-Path $LogDir 'app-stdout.log'
$stderr = Join-Path $LogDir 'app-stderr.log'
$stdin = Join-Path $LogDir 'app-stdin.txt'
Set-Content -Path $stdin -Value '' -Encoding ascii
Set-Content -Path $stdout -Value '' -Encoding utf8
Set-Content -Path $stderr -Value '' -Encoding utf8

Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class WinCap2 {
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
                bool ok = PrintWindow(h, dc, 2);
                g.ReleaseHdc(dc);
                if (!ok) return false;
            }
            bmp.Save(path, ImageFormat.Png);
        }
        return true;
    }
}
'@ -ReferencedAssemblies System.Drawing

$proc = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -RedirectStandardInput $stdin

Start-Sleep -Milliseconds $WaitMs

$hwnd = [WinCap2]::FindMainWindow([uint32]$proc.Id)
$rc = 0
if ($hwnd -eq [IntPtr]::Zero) {
    Write-Host 'no visible window found'
    $rc = 1
} else {
    $title = New-Object System.Text.StringBuilder 512
    [void][WinCap2]::GetWindowText($hwnd, $title, 512)
    Write-Host ("window: hwnd=0x{0:X} title='{1}'" -f $hwnd.ToInt64(), $title.ToString())
    if ([WinCap2]::Capture($hwnd, $Out)) {
        Write-Host "captured: $Out"
    } else {
        Write-Host 'PrintWindow failed'
        $rc = 2
    }
}

if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
Start-Sleep -Milliseconds 400

Write-Host '--- stdout ---'
if (Test-Path $stdout) { Get-Content $stdout }
Write-Host '--- stderr ---'
if (Test-Path $stderr) { Get-Content $stderr }
exit $rc
