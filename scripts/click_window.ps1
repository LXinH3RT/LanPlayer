# 在指定窗口的客户区坐标上点一下（真实鼠标事件，走 user32 SendInput 的那套语义）。
#
# 为什么需要它：Flutter 的 hover / tap 都从 Win32 的真实鼠标位置采样，
# PostMessage(WM_LBUTTONDOWN) 不会让引擎产生 tap，必须真的移动光标 + 按下/抬起。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\click_window.ps1 `
#       -ProcessName lanplayer -X 1184 -Y 670 [-Delay 800] [-WaitMs 3000]
param(
    [string]$ProcessName = 'lanplayer',
    [Parameter(Mandatory = $true)][int]$X,
    [Parameter(Mandatory = $true)][int]$Y,
    [int]$Delay = 800,          # 点击前等多久（让界面先稳定）
    [int]$WaitMs = 0,           # 点击后再等多久（不填就不等）
    [switch]$DoubleClick
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class LpClick {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT p);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    public const uint LEFTDOWN = 0x0002;
    public const uint LEFTUP = 0x0004;
}
'@

[void][LpClick]::SetProcessDPIAware()

$proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) {
    Write-Host "error: 没有找到带窗口的 $ProcessName 进程"
    exit 2
}
$hwnd = $proc.MainWindowHandle
Write-Host ("window: hwnd=0x{0:X} title='{1}'" -f [int64]$hwnd, $proc.MainWindowTitle)

# 前置窗口 + 找 FLUTTERVIEW 子窗口（客户区坐标系以它为基准）。
[void][LpClick]::ShowWindow($hwnd, 9)      # SW_RESTORE
[void][LpClick]::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds 300

$view = [LpClick]::FindWindowEx($hwnd, [IntPtr]::Zero, 'FLUTTERVIEW', $null)
if ($view -ne [IntPtr]::Zero) {
    $origin = New-Object LpClick+POINT
    $origin.X = 0; $origin.Y = 0
    [void][LpClick]::ClientToScreen($view, [ref]$origin)
    Write-Host ("view: FLUTTERVIEW at {0},{1}" -f $origin.X, $origin.Y)
} else {
    $origin = New-Object LpClick+POINT
    $origin.X = 0; $origin.Y = 0
    [void][LpClick]::ClientToScreen($hwnd, [ref]$origin)
    Write-Host ("view: (no FLUTTERVIEW) client origin {0},{1}" -f $origin.X, $origin.Y)
}

if ($Delay -gt 0) { Start-Sleep -Milliseconds $Delay }

$targetX = $origin.X + $X
$targetY = $origin.Y + $Y
[void][LpClick]::SetCursorPos($targetX, $targetY)
Start-Sleep -Milliseconds 120
# 再抖一下，确保引擎收到 WM_MOUSEMOVE（只设一次位置光标已经在同一处时不会产生移动）。
[void][LpClick]::SetCursorPos($targetX + 1, $targetY + 1)
Start-Sleep -Milliseconds 60
[void][LpClick]::SetCursorPos($targetX, $targetY)
Start-Sleep -Milliseconds 120

$rounds = if ($DoubleClick) { 2 } else { 1 }
for ($i = 0; $i -lt $rounds; $i++) {
    [LpClick]::mouse_event([LpClick]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [LpClick]::mouse_event([LpClick]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
    if ($i -lt $rounds - 1) { Start-Sleep -Milliseconds 120 }
}
Write-Host ("clicked client ({0},{1}) -> screen ({2},{3}) x{4}" -f $X, $Y, $targetX, $targetY, $rounds)

if ($WaitMs -gt 0) { Start-Sleep -Milliseconds $WaitMs }
exit 0
