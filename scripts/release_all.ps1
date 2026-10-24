# Publish one release with all three platform packages.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\release_all.ps1
#   powershell ... -Version 0.1.3
#   powershell ... -Version 0.1.3 -BodyFile dist\release-notes.md -DryRun
#
# Every release ships Windows, macOS and Android together. If one of the three
# files is missing under dist\, this script refuses to upload anything: a
# release with a missing platform is worse than a late release, because the
# download page silently lies about what the version supports.
#
# Expected assets (all in dist\):
#   LanPlayer-<version>-windows-x64-setup.exe   scripts\build_windows_installer.ps1
#   LanPlayer-<version>-macos-arm64.dmg         scripts\build_macos_dmg.sh
#   LanPlayer-<version>-android-arm64.apk       scripts\build_android_apk.sh
#
# The version defaults to the one in app/pubspec.yaml (that is the single
# source of truth since 0.1.2), so the tag, the asset names and the version
# string compiled into the binaries cannot drift apart.
#
# This file must stay pure ASCII. Windows PowerShell 5.1 reads a BOM-less .ps1
# as ANSI, so a multi-byte character here breaks the parser.
[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$Tag = '',
    [string]$BodyFile = '',
    [string]$Repo = 'LXinH3RT/LanPlayer',
    [switch]$DryRun,
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

if (-not $Version) {
    $pubspec = Join-Path $root 'app\pubspec.yaml'
    $line = Select-String -Path $pubspec -Pattern '^\s*version:\s*([0-9]+\.[0-9]+\.[0-9]+)' | Select-Object -First 1
    if (-not $line) { Write-Host 'error: cannot read version from app/pubspec.yaml' -ForegroundColor Red; exit 1 }
    $Version = $line.Matches[0].Groups[1].Value
}
if (-not $Tag) { $Tag = "v$Version" }

$assetNames = @(
    "LanPlayer-$Version-windows-x64-setup.exe",
    "LanPlayer-$Version-macos-arm64.dmg",
    "LanPlayer-$Version-android-arm64.apk"
)

Write-Host "== release $Tag ($Repo) =="

# Fail before touching the network: one missing package means no release.
$missing = @()
foreach ($name in $assetNames) {
    $path = Join-Path $root (Join-Path 'dist' $name)
    if (-not (Test-Path $path)) {
        $missing += $name
    }
}
if ($missing.Count -gt 0) {
    Write-Host 'error: all three platform packages must exist before releasing.' -ForegroundColor Red
    foreach ($name in $missing) { Write-Host "  missing: dist\$name" -ForegroundColor Red }
    Write-Host '  build them with:'
    Write-Host '    powershell -File scripts\build_windows_installer.ps1'
    Write-Host '    VERSION=<ver> ./scripts/build_macos_dmg.sh      (on the Mac)'
    Write-Host '    VERSION=<ver> ./scripts/build_android_apk.sh   (on the Mac)'
    exit 1
}

foreach ($name in $assetNames) {
    $path = Join-Path $root (Join-Path 'dist' $name)
    $size = (Get-Item $path).Length
    $hash = (Get-FileHash -Path $path -Algorithm SHA256).Hash
    Write-Host ("  {0,-45} {1,12:N0} bytes  {2}" -f $name, $size, $hash)
}

if ($DryRun) {
    Write-Host 'dry run: nothing uploaded'
    exit 0
}

# Token: reuse the one the Windows credential manager already holds for
# github.com, so this script needs no extra secret on disk.
$credInput = "protocol=https`nhost=github.com`n`n"
$credOut = $credInput | & git credential fill 2>$null
$token = ($credOut | Select-String -Pattern '^password=(.+)$').Matches.Groups[1].Value
if (-not $token) {
    Write-Host 'error: no GitHub token in the credential manager (git credential fill)' -ForegroundColor Red
    exit 1
}

$api = "https://api.github.com/repos/$Repo"
$uploadHost = "https://uploads.github.com/repos/$Repo"
# --ssl-no-revoke: Windows curl goes through schannel and fails on the
# revocation check (CRYPT_E_NO_REVOCATION_CHECK).
$curl = 'curl.exe'

function Invoke-Api {
    param(
        [string]$Method,
        [string]$Url,
        [string]$JsonFile = '',
        [string]$OutFile = ''
    )
    # Arguments only; the command is splatted separately. `& $array` does not
    # splat in Windows PowerShell 5.1 - it stringifies the whole array and then
    # fails with "not recognized as the name of a cmdlet".
    $curlArgs = @('-sS', '--ssl-no-revoke', '-X', $Method, $Url,
        '-H', "Authorization: Bearer $token",
        '-H', 'Accept: application/vnd.github+json',
        '-H', 'X-GitHub-Api-Version: 2022-11-28')
    if ($JsonFile) { $curlArgs += @('-H', 'Content-Type: application/json', '-d', "@$JsonFile") }
    if ($OutFile) { $curlArgs += @('-o', $OutFile) }
    $response = & $curl @curlArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "error: $Method $Url failed: $response" -ForegroundColor Red
        exit 1
    }
    return ($response -join "`n")
}

$tmp = Join-Path $root '.tools\tmp'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# 1. Find or create the release. Re-running after a partial upload must reuse
#    the existing release instead of failing on a duplicate tag.
#    curl without -f exits 0 on a 404, so the lookup is judged by the JSON body
#    (a missing release answers {"message":"Not Found"}); the file is removed
#    first so a stale response from an earlier run can never be mistaken for it.
$releaseJson = Join-Path $tmp 'release-existing.json'
Remove-Item -Force $releaseJson -ErrorAction SilentlyContinue
Invoke-Api -Method GET -Url "$api/releases/tags/$Tag" -OutFile $releaseJson | Out-Null
$release = $null
if (Test-Path $releaseJson) {
    # GitHub answers in UTF-8; -Encoding UTF8 is not optional here because the
    # default on this machine would decode the body as GBK.
    try { $release = Get-Content -Path $releaseJson -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $release = $null }
}
if ($release -and $release.tag_name) {
    Write-Host "  reusing release id $($release.id)"
} else {
    $body = ''
    if ($BodyFile) {
        if (-not (Test-Path $BodyFile)) { Write-Host "error: missing body file $BodyFile" -ForegroundColor Red; exit 1 }
        # The [string] cast is load bearing: Windows PowerShell 5.1 hands back
        # the -Raw result in a wrapper that ConvertTo-Json turns into
        # {"value": "...", "ReadCount": 1, ...} instead of a plain string, and
        # GitHub then rejects the request with "For 'properties/body'".
        [string]$body = Get-Content -Path $BodyFile -Raw -Encoding UTF8
    } else {
        $body = "Windows / macOS / Android packages for $Version."
    }
    $payload = [ordered]@{
        tag_name         = $Tag
        target_commitish = 'main'
        name             = "LanPlayer $Version"
        body             = $body
        draft            = $false
        prerelease       = $false
    } | ConvertTo-Json -Depth 4
    $jsonPath = Join-Path $tmp 'release-create.json'
    [System.IO.File]::WriteAllText($jsonPath, $payload, (New-Object System.Text.UTF8Encoding($false)))
    $created = Invoke-Api -Method POST -Url "$api/releases" -JsonFile $jsonPath -OutFile $releaseJson
    $release = Get-Content -Path $releaseJson -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $release.id) {
        # curl exits 0 on an API error too, so a missing id means GitHub said no.
        $why = Get-Content -Path $releaseJson -Raw -Encoding UTF8
        Write-Host "error: creating release $Tag failed: $why" -ForegroundColor Red
        exit 1
    }
    Write-Host "  created release id $($release.id) (tag $Tag)"
}
$releaseId = $release.id

# 2. Upload the three assets. GitHub refuses a duplicate asset name, so delete
#    an existing one first: re-running the script must converge, not 422.
$assetsJson = Join-Path $tmp 'release-assets.json'
Remove-Item -Force $assetsJson -ErrorAction SilentlyContinue
Invoke-Api -Method GET -Url "$api/releases/$releaseId/assets" -OutFile $assetsJson | Out-Null
$existingAssets = @()
if (Test-Path $assetsJson) {
    try { $existingAssets = Get-Content -Path $assetsJson -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $existingAssets = @() }
}

foreach ($name in $assetNames) {
    $old = $existingAssets | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if ($old) {
        Write-Host "  replacing existing asset $name (id $($old.id))"
        Invoke-Api -Method DELETE -Url "$api/releases/assets/$($old.id)" | Out-Null
    }
    $path = Join-Path $root (Join-Path 'dist' $name)
    Write-Host "  uploading $name"
    $response = & $curl -sS --ssl-no-revoke -X POST "$uploadHost/releases/$releaseId/assets?name=$name" `
        -H "Authorization: Bearer $token" `
        -H 'Content-Type: application/octet-stream' `
        -H 'Accept: application/vnd.github+json' `
        --data-binary "@$path" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "error: upload of $name failed: $response" -ForegroundColor Red
        exit 1
    }
    $uploaded = $null
    try { $uploaded = ($response -join "`n") | ConvertFrom-Json } catch { $uploaded = $null }
    if (-not $uploaded -or -not $uploaded.id) {
        Write-Host "error: upload of $name returned no asset id: $response" -ForegroundColor Red
        exit 1
    }
    $localSize = (Get-Item $path).Length
    if ($uploaded.size -ne $localSize) {
        Write-Host "error: $name uploaded $($uploaded.size) bytes, local file is $localSize" -ForegroundColor Red
        exit 1
    }
    Write-Host "    ok id=$($uploaded.id) size=$($uploaded.size)"
}

# 3. Optional round trip: download every asset and compare SHA256. Slow (about
#    120 MB of traffic) but it is the only check that proves the bytes arrived
#    intact rather than merely that a size matched.
if ($Verify) {
    $dl = Join-Path $tmp 'verify-download'
    New-Item -ItemType Directory -Force -Path $dl | Out-Null
    Invoke-Api -Method GET -Url "$api/releases/$releaseId/assets" -OutFile $assetsJson | Out-Null
    $finalAssets = Get-Content -Path $assetsJson -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($name in $assetNames) {
        $asset = $finalAssets | Where-Object { $_.name -eq $name } | Select-Object -First 1
        $dest = Join-Path $dl $name
        & $curl -sSL --ssl-no-revoke -H "Authorization: Bearer $token" `
            -H 'Accept: application/octet-stream' `
            -o $dest "$api/releases/assets/$($asset.id)" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "error: download of $name failed" -ForegroundColor Red; exit 1 }
        $local = (Get-FileHash -Path (Join-Path $root (Join-Path 'dist' $name)) -Algorithm SHA256).Hash
        $remote = (Get-FileHash -Path $dest -Algorithm SHA256).Hash
        if ($local -ne $remote) {
            Write-Host "error: $name sha256 mismatch (local $local, remote $remote)" -ForegroundColor Red
            exit 1
        }
        Write-Host "  verified $name"
    }
    Remove-Item -Recurse -Force $dl
}

Write-Host ''
Write-Host "published: https://github.com/$Repo/releases/tag/$Tag" -ForegroundColor Green
Write-Host "release id: $releaseId"
foreach ($name in $assetNames) { Write-Host "  $name" }
