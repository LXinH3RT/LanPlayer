# image_stats.ps1 - sample an image region with LockBits and print colour stats.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tool/image_stats.ps1 -Path a.png [-Crop x,y,w,h] [-Save out.png] [-Bands n]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Crop = "",
    [string]$Save = "",
    [int]$Top = 8
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Drawing

$src = [System.Drawing.Bitmap]::FromFile((Resolve-Path $Path).Path)
try {
    $parts = @()
    if ($Crop -ne "") { $parts = $Crop -split ',' | ForEach-Object { [int]($_.Trim()) } }

    if ($parts.Count -eq 4) {
        $rect = New-Object System.Drawing.Rectangle $parts[0], $parts[1], $parts[2], $parts[3]
        $img = $src.Clone($rect, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    }
    else {
        $img = New-Object System.Drawing.Bitmap $src
    }

    if ($Save -ne "") {
        $img.Save($Save, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Output "saved: $Save ($($img.Width)x$($img.Height))"
    }

    $w = $img.Width; $h = $img.Height
    $data = $img.LockBits(
        (New-Object System.Drawing.Rectangle 0, 0, $w, $h),
        [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $len = [Math]::Abs($data.Stride) * $h
        $buf = New-Object byte[] $len
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $len)
        $stride = $data.Stride

        $rSum = 0L; $gSum = 0L; $bSum = 0L; $n = 0L
        $hist = @{}
        for ($y = 0; $y -lt $h; $y++) {
            $row = $y * $stride
            for ($x = 0; $x -lt $w; $x++) {
                $i = $row + $x * 4
                $b = [int]$buf[$i]; $g = [int]$buf[$i + 1]; $r = [int]$buf[$i + 2]
                $rSum += $r; $gSum += $g; $bSum += $b; $n++
                $k = "$r,$g,$b"
                if ($hist.ContainsKey($k)) { $hist[$k] = $hist[$k] + 1 } else { $hist[$k] = 1 }
            }
        }

        Write-Output ("size={0}x{1} colors={2}" -f $w, $h, $hist.Count)
        Write-Output ("mean r={0:N1} g={1:N1} b={2:N1}" -f ($rSum / $n), ($gSum / $n), ($bSum / $n))

        $ranked = $hist.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Top
        foreach ($e in $ranked) {
            Write-Output ("  {0,-14} {1,10}  {2:P1}" -f $e.Key, $e.Value, ($e.Value / $n))
        }
    }
    finally {
        $img.UnlockBits($data)
    }
    $img.Dispose()
}
finally {
    $src.Dispose()
}
