# Patch the bundled Flutter SDK so `flutter build windows` works with Visual
# Studio 2026 (major version 18).
#
# Why this is needed
# ------------------
# flutter_tools decides the CMake generator itself:
#
#   .tools/flutter-sdk/packages/flutter_tools/lib/src/windows/visual_studio.dart
#     String? get cmakeGenerator {
#       return switch (_majorVersion) {
#         17 => 'Visual Studio 17 2022',
#         _  => 'Visual Studio 16 2019',
#       };
#     }
#
# Visual Studio 18 therefore falls into the `_` arm and CMake is asked for a
# "Visual Studio 16 2019" generator, which does not exist on the machine:
#
#   CMake Error: Generator Visual Studio 16 2019 could not find any instance
#   of Visual Studio.
#
# Flutter 3.27.4 predates VS 2026, so there is no upstream support to rely on.
# The SDK lives under the git-ignored .tools/ directory, so patching it is a
# local tool cache change rather than a modification of tracked sources; the
# patch is idempotent and re-applied by scripts/build_windows_desktop.ps1.
#
# The generator name is discovered from `cmake --help` (which always lists the
# generators the installed CMake knows) and injected as an explicit case, so a
# future VS 19 / VS 20 would only need `-MajorVersion 19`.

[CmdletBinding()]
param(
    # Visual Studio major version to support. 18 = Visual Studio 2026.
    [int]$MajorVersion = 18,
    # Flutter SDK root; defaults to .tools\flutter-sdk next to this script.
    [string]$FlutterRoot = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $FlutterRoot) { $FlutterRoot = Join-Path $root '.tools\flutter-sdk' }

$file = Join-Path $FlutterRoot 'packages\flutter_tools\lib\src\windows\visual_studio.dart'
if (-not (Test-Path $file)) {
    Write-Output "!! no flutter_tools sources at $file (SDK not downloaded?)"
    exit 1
}

# Find the generator string CMake knows for this Visual Studio major version,
# e.g. "Visual Studio 18 2026".  Matching is on the major number followed by a
# four digit year so "16 2019" cannot be mistaken for "18 2026".
$cmake = $null
foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $base) { continue }
    $vsRoot = Join-Path $base 'Microsoft Visual Studio'
    if (-not (Test-Path $vsRoot)) { continue }
    foreach ($major in (Get-ChildItem -Path $vsRoot -Directory -ErrorAction SilentlyContinue)) {
        foreach ($edition in (Get-ChildItem -Path $major.FullName -Directory -ErrorAction SilentlyContinue)) {
            $candidate = Join-Path $edition.FullName 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
            if (Test-Path $candidate) { $cmake = $candidate; break }
        }
        if ($cmake) { break }
    }
    if ($cmake) { break }
}
if (-not $cmake) {
    $cmd = Get-Command cmake.exe -ErrorAction SilentlyContinue
    if ($cmd) { $cmake = $cmd.Source }
}
if (-not $cmake) {
    Write-Output '!! cmake.exe not found; cannot discover the generator name'
    exit 1
}

$help = & $cmake --help 2>&1 | Out-String
$generator = $null
foreach ($line in ($help -split "`r?`n")) {
    if ($line -match "^\s*\*?\s*(Visual Studio $MajorVersion\s+\d{4})(?!\d)") {
        $generator = $Matches[1].Trim()
        break
    }
}
if (-not $generator) {
    Write-Output "!! cmake does not offer a 'Visual Studio $MajorVersion' generator"
    exit 1
}

$text = [System.IO.File]::ReadAllText($file)
$marker = "// [lanplayer] Visual Studio $MajorVersion support (scripts/patch_flutter_tools.ps1)"

if ($text.Contains($marker)) {
    Write-Output "flutter_tools: already patched for $generator"
    exit 0
}

$old = @'
  String? get cmakeGenerator {
    // From https://cmake.org/cmake/help/v3.22/manual/cmake-generators.7.html#visual-studio-generators
    return switch (_majorVersion) {
      17 => 'Visual Studio 17 2022',
      _  => 'Visual Studio 16 2019',
    };
  }
'@

$new = @"
  String? get cmakeGenerator {
    // From https://cmake.org/cmake/help/v3.22/manual/cmake-generators.7.html#visual-studio-generators
    // $marker
    return switch (_majorVersion) {
      $MajorVersion => '$generator',
      17 => 'Visual Studio 17 2022',
      _  => 'Visual Studio 16 2019',
    };
  }
"@

# Normalise line endings of the searched text so the replace works on a
# checkout whose files use CRLF.
$oldCrlf = $old -replace "`r?`n", "`r`n"
$newCrlf = $new -replace "`r?`n", "`r`n"

if ($text.Contains($old)) {
    $text = $text.Replace($old, $newCrlf)
} elseif ($text.Contains($oldCrlf)) {
    $text = $text.Replace($oldCrlf, $newCrlf)
} else {
    Write-Output '!! cmakeGenerator getter does not match the expected shape'
    Write-Output '   the SDK may already be newer; remove this patch if upstream supports VS 2026'
    exit 1
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($file, $text, $utf8)
Write-Output "flutter_tools: patched cmakeGenerator -> '$generator' (VS major $MajorVersion)"
