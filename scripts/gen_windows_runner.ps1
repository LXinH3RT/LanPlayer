# Generates app/windows/ from the Flutter SDK's own Windows runner templates.
#
# `flutter create --platforms=windows .` does exactly this; we reproduce it with
# a script so the desktop runner can be generated on machines where the flutter
# tool cannot run (no git / no interactive console) and so the generated tree is
# reviewable in the repo.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/gen_windows_runner.ps1
param(
    [string]$ProjectName = 'lanplayer',
    [string]$Organization = 'dev.lanplayer'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sdk = Join-Path $root '.tools\flutter-sdk'
$tmpl = Join-Path $sdk 'packages\flutter_tools\templates\app_shared\windows.tmpl'
$dest = Join-Path $root 'app\windows'

if (-not (Test-Path $tmpl)) {
    throw 'Flutter SDK templates not found - run: python tool/fetch_deps.py flutter'
}

function Expand-Template([string]$text) {
    # Drop mustache sections that only apply to plugin projects.
    $text = [regex]::Replace($text, '(?s)\{\{#withPlatformChannelPluginHook\}\}.*?\{\{/withPlatformChannelPluginHook\}\}', '')
    $text = $text.Replace('{{projectName}}', $ProjectName)
    $text = $text.Replace('{{pluginProjectName}}', $ProjectName)
    $text = $text.Replace('{{organization}}', $Organization)
    $text = $text.Replace('{{year}}', (Get-Date).Year.ToString())
    $text = $text.Replace('{{description}}', 'LanPlayer')
    $text = $text.Replace('{{windowsIdentifier}}', $Organization)
    return $text
}

$binaryExtensions = @('.ico', '.png', '.jpg')
$created = 0

Get-ChildItem -LiteralPath $tmpl -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($tmpl.Length).TrimStart('\')
    $target = Join-Path $dest $rel
    $target = $target -replace '\.tmpl$', ''
    $target = $target -replace '\.img$', ''

    $dir = Split-Path -Parent $target
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    if ($binaryExtensions -contains [IO.Path]::GetExtension($target)) {
        Copy-Item $_.FullName $target -Force
    } else {
        $text = [IO.File]::ReadAllText($_.FullName)
        $expanded = Expand-Template $text
        [IO.File]::WriteAllText($target, $expanded, (New-Object System.Text.UTF8Encoding($false)))
    }
    Write-Host ('   ' + $rel.Replace('.tmpl', ''))
    $created++
}

Write-Host "`ngenerated $created files in $dest" -ForegroundColor Green
Write-Host 'next: flutter pub get regenerates windows/flutter/generated_plugins.cmake'
