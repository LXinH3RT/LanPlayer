# Launch the Release lanplayer.exe with the "open add-server page + auto scan" hook,
# grab one full-screen capture, and print the log. Used to verify LAN scanning in the
# real program. ASCII only on purpose: Windows PowerShell 5.1 reads BOM-less files as
# ANSI, which breaks any non-ASCII literal.
param(
    [string]$Exe = '',
    [string]$StateDir = '',
    [string]$Out = '',
    [string]$LogDir = '',
    [int]$WaitMs = 9000
)
$ErrorActionPreference = 'Stop'

# Defaults hang off the repository this script lives in, not off one machine's
# directory layout.
$Root = Split-Path -Parent $PSScriptRoot
if (-not $Exe) { $Exe = Join-Path $Root 'app\build\windows\x64\runner\Release\lanplayer.exe' }
if (-not $StateDir) { $StateDir = Join-Path $Root 'build\state-lanscan' }
if (-not $Out) { $Out = Join-Path $Root 'build\shots\lan-scan.png' }
if (-not $LogDir) { $LogDir = Join-Path $Root 'build\shots\lan-log' }
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class LpCap2 {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

[void][LpCap2]::SetProcessDPIAware()

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir  | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null

Get-Process lanplayer -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400

$env:LANPLAYER_STATE_DIR = $StateDir
$env:LANPLAYER_UI = 'add-server'
$env:LANPLAYER_AUTOSCAN = '1'

$stdout = Join-Path $LogDir 'app-stdout.log'
$stderr = Join-Path $LogDir 'app-stderr.log'
Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue

$proc = Start-Process -FilePath $Exe -PassThru `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr
Start-Sleep -Milliseconds 1500

$hwnd = [IntPtr]::Zero
for ($i = 0; $i -lt 40; $i++) {
    $p = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if ($p -and $p.MainWindowHandle -ne 0) { $hwnd = $p.MainWindowHandle; break }
    Start-Sleep -Milliseconds 250
}
if ($hwnd -eq [IntPtr]::Zero) { Write-Host 'error: no window'; exit 2 }

[void][LpCap2]::ShowWindow($hwnd, 9)
[void][LpCap2]::SetWindowPos($hwnd, [IntPtr](-1), 0, 0, 0, 0, 0x0001 -bor 0x0002)
[void][LpCap2]::BringWindowToTop($hwnd)
[void][LpCap2]::SetForegroundWindow($hwnd)

Start-Sleep -Milliseconds $WaitMs

$r = New-Object LpCap2+RECT
[void][LpCap2]::GetWindowRect($hwnd, [ref]$r)
$w = $r.Right - $r.Left
$h = $r.Bottom - $r.Top
Write-Host ("window: hwnd=0x{0:X} rect={1}x{2} at {3},{4} foreground={5}" -f `
    [int64]$hwnd, $w, $h, $r.Left, $r.Top, ([LpCap2]::GetForegroundWindow() -eq $hwnd))

$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$full = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$g = [System.Drawing.Graphics]::FromImage($full)
$g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $full.Size)
$g.Dispose()

$crop = New-Object System.Drawing.Bitmap $w, $h
$g2 = [System.Drawing.Graphics]::FromImage($crop)
$g2.DrawImage($full, (New-Object System.Drawing.Rectangle 0, 0, $w, $h),
    (New-Object System.Drawing.Rectangle $r.Left, $r.Top, $w, $h),
    [System.Drawing.GraphicsUnit]::Pixel)
$g2.Dispose()
$crop.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$crop.Dispose()
$full.Dispose()
Write-Host "captured: $Out"

if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
Start-Sleep -Milliseconds 400

Write-Host '--- stdout ---'
Get-Content $stdout -Encoding UTF8 -ErrorAction SilentlyContinue
Write-Host '--- stderr (tail) ---'
Get-Content $stderr -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 6
exit 0
