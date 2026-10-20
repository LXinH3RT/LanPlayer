# Capture the LanPlayer window the way a user would see it.
#
# Why this exists: `PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT)` returns only the
# non-client frame plus a black client area for Flutter windows that are not the
# foreground window (ANGLE/D3D swaps are not replayed by PrintWindow).  Copying
# the pixels straight off the screen after bringing the window to the front is
# the only capture that shows what the renderer really produced.
#
#   powershell -File scripts\capture_screen.ps1 -Exe <lanplayer.exe> -Out <png>
#
#   -WholeScreen   capture the entire desktop instead of the window rectangle.
#                  On a scaled display the Flutter view can be composited at a
#                  different offset than GetWindowRect reports, so a window-rect
#                  grab may miss the client area entirely; the whole screen
#                  always contains it.
#   -Retries N     re-raise the window and capture again when the shot does not
#                  contain the expected colour.  SetForegroundWindow is only a
#                  request: if another window keeps the foreground the desktop
#                  (not the app) is what gets copied, which is how a colour probe
#                  silently turned into an all-white PNG twice.  Defaults to 4.
#   -ExpectColor  "R,G,B" the capture must contain (e.g. "253,0,0" for the red
#                  probe).  When given, the shot is rejected and retried until
#                  -MinMatch of sampled pixels match within -ColorTolerance.
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [string]$Open = '',
  [string]$Browse = '',
  [string]$User = '',
  [string]$Pass = '',
  [string]$StateDir = '',
  [string]$LogDir = '',
  [string]$Out = '',
  [int]$WaitMs = 9000,
  [int]$Retries = 4,
  [string]$ExpectColor = '',
  [double]$MinMatch = 0.20,
  [int]$ColorTolerance = 20,
  [switch]$WholeScreen
)

$ErrorActionPreference = 'Continue'

if (-not $LogDir) { $LogDir = Join-Path (Split-Path -Parent $Out) 'log' }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$stdout = Join-Path $LogDir 'app-stdout.log'
$stderr = Join-Path $LogDir 'app-stderr.log'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class ScreenCap {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool alt);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

  public static IntPtr Find(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint id; GetWindowThreadProcessId(h, out id);
      if (id != pid || !IsWindowVisible(h)) return true;
      RECT r; GetWindowRect(h, out r);
      if (r.Right - r.Left < 200 || r.Bottom - r.Top < 200) return true;
      if (GetWindowTextLength(h) == 0) return true;
      found = h;
      return false;
    }, IntPtr.Zero);
    return found;
  }
}
'@

$env:LANPLAYER_STATE_DIR = $StateDir
if ($Open) { $env:LANPLAYER_OPEN = $Open } else { Remove-Item Env:LANPLAYER_OPEN -ErrorAction SilentlyContinue }
if ($Browse) { $env:LANPLAYER_BROWSE = $Browse } else { Remove-Item Env:LANPLAYER_BROWSE -ErrorAction SilentlyContinue }
if ($User) { $env:LANPLAYER_USER = $User } else { Remove-Item Env:LANPLAYER_USER -ErrorAction SilentlyContinue }
if ($Pass) { $env:LANPLAYER_PASS = $Pass } else { Remove-Item Env:LANPLAYER_PASS -ErrorAction SilentlyContinue }

$proc = Start-Process -FilePath $Exe -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
Start-Sleep -Milliseconds $WaitMs

# NOTE: $ExpectColor is a [string] parameter, so it must not be reassigned to an
# array here -- PowerShell silently coerces "@(253,0,0)" back to the string
# "253 0 0", $ExpectColor[0] then yields the character '2', and every comparison
# quietly fails (this cost a full retry sweep reporting a 0.2% colour match on an
# image that was 88.5% red).  Parse into separate ints instead.
$hasExpect = $false
$ecR = 0; $ecG = 0; $ecB = 0
if ($ExpectColor) {
  $parts = $ExpectColor -split ','
  if ($parts.Count -ne 3) { throw "-ExpectColor wants 'R,G,B', got '$ExpectColor'" }
  $ecR = [int]$parts[0]; $ecG = [int]$parts[1]; $ecB = [int]$parts[2]
  $hasExpect = $true
}

# A window that is not the foreground window is simply not in the copy: the
# desktop is.  SetForegroundWindow alone is a request the shell may refuse, and a
# refused request produced an all-white "proof" during the colour-order work, so
# raise the window three ways and then verify the shot is not blank.
function Raise-Window([IntPtr]$h) {
  [ScreenCap]::ShowWindow($h, 9) | Out-Null
  [ScreenCap]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0003) | Out-Null
  [ScreenCap]::BringWindowToTop($h) | Out-Null
  [ScreenCap]::SetForegroundWindow($h) | Out-Null
  [ScreenCap]::SwitchToThisWindow($h, $true) | Out-Null
  Start-Sleep -Milliseconds 700
}

# Fraction of sampled pixels that match the expected colour.  This is the only
# reliable "did we capture the app" test for a colour probe: an all-white desktop
# capture and a solid-red video frame are both flat histograms (measured 49% vs
# 88% dominant-colour), so flatness cannot tell them apart -- the colour itself
# can.  Returns -1 when no expectation was given.
function Get-ColorMatch([System.Drawing.Bitmap]$b, [int]$er, [int]$eg, [int]$eb, [int]$tol) {
  $hit = 0
  $n = 0
  for ($y = 0; $y -lt $b.Height; $y += 8) {
    for ($x = 0; $x -lt $b.Width; $x += 8) {
      $p = $b.GetPixel($x, $y)
      if ([Math]::Abs($p.R - $er) -le $tol -and [Math]::Abs($p.G - $eg) -le $tol -and [Math]::Abs($p.B - $eb) -le $tol) {
        $hit++
      }
      $n++
    }
  }
  return [double]$hit / [double]$n
}

$hwnd = [ScreenCap]::Find([uint32]$proc.Id)
if ($hwnd -eq [IntPtr]::Zero) {
  Write-Output 'window: not found'
} else {
  Raise-Window $hwnd
  $r = New-Object ScreenCap+RECT
  [ScreenCap]::GetWindowRect($hwnd, [ref]$r) | Out-Null
  $w = $r.Right - $r.Left
  $h = $r.Bottom - $r.Top
  $fg = [ScreenCap]::GetForegroundWindow()
  Write-Output ("window: hwnd=0x{0:X} rect={1}x{2} at {3},{4} foreground={5}" -f `
    $hwnd.ToInt64(), $w, $h, $r.Left, $r.Top, ($fg -eq $hwnd))
}

if ($Out -and ($WholeScreen -or $hwnd -ne [IntPtr]::Zero)) {
  $attempt = 0
  $match = -1.0
  while ($attempt -lt $Retries) {
    $attempt++
    if ($WholeScreen) {
      $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
      if ($attempt -eq 1) {
        Write-Output ("screen: {0}x{1} at {2},{3}" -f $bounds.Width, $bounds.Height, $bounds.X, $bounds.Y)
      }
      $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      $g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0,
        (New-Object System.Drawing.Size $bounds.Width, $bounds.Height))
    } else {
      $bmp = New-Object System.Drawing.Bitmap $w, $h
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
    }
    $g.Dispose()
    if ($hasExpect) {
      $match = Get-ColorMatch $bmp $ecR $ecG $ecB $ColorTolerance
    }
    $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    if ($match -lt 0 -or $match -ge $MinMatch) { break }
    Write-Output ("attempt {0}/{1}: expected colour only {2:P1} of pixels, re-raising" -f $attempt, $Retries, $match)
    if ($hwnd -ne [IntPtr]::Zero) { Raise-Window $hwnd }
  }
  $invalid = $false
  if ($match -ge 0) {
    Write-Output ("captured: {0} (expected-colour match={1:P1}, attempts={2})" -f $Out, $match, $attempt)
    if ($match -lt $MinMatch) {
      Write-Output 'warning: expected colour not found; treat this capture as invalid evidence'
      $invalid = $true
    }
  } else {
    Write-Output ("captured: {0} (attempts={1})" -f $Out, $attempt)
  }
}

if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
Start-Sleep -Milliseconds 300

Write-Output '--- stdout ---'
if (Test-Path $stdout) { Get-Content $stdout -Encoding UTF8 }
Write-Output '--- stderr ---'
if (Test-Path $stderr) { Get-Content $stderr -Encoding UTF8 }

if ($invalid) { exit 3 }
