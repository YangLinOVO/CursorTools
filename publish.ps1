#Requires -Version 5.1
<#
.SYNOPSIS
    Build Cursor Version Tool (Tauri 2) into .\dist
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$app  = Join-Path $root 'src\CursorVersionTool'
$out  = Join-Path $root 'dist'

if (-not (Test-Path -LiteralPath (Join-Path $app 'package.json'))) {
    throw "Tauri project not found: $app"
}

Write-Host "Building CursorVersionTool (Tauri 2, release)..." -ForegroundColor Cyan

Push-Location $app
try {
    npm install
    if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit code $LASTEXITCODE" }

    npm run tauri -- build
    if ($LASTEXITCODE -ne 0) { throw "tauri build failed with exit code $LASTEXITCODE" }
}
finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath $out)) {
    New-Item -ItemType Directory -Path $out | Out-Null
}

$releaseDir = Join-Path $app 'src-tauri\target\release'
$exeSrc = Join-Path $releaseDir 'cursor-version-tool.exe'
$bundleDir = Join-Path $releaseDir 'bundle\nsis'
$exeDst = Join-Path $out 'CursorVersionTool.exe'

if (-not (Test-Path -LiteralPath $exeSrc)) {
    throw "Expected release exe missing: $exeSrc"
}

Copy-Item -LiteralPath $exeSrc -Destination $exeDst -Force

$nsis = Get-ChildItem -LiteralPath $bundleDir -Filter '*.exe' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if ($nsis) {
    Copy-Item -LiteralPath $nsis.FullName -Destination (Join-Path $out $nsis.Name) -Force
}

$info = Get-Item -LiteralPath $exeDst
Write-Host ""
Write-Host ("OK  {0}" -f $exeDst) -ForegroundColor Green
Write-Host ("    Size: {0:N1} MB" -f ($info.Length / 1MB)) -ForegroundColor DarkGray
if ($nsis) {
    Write-Host ("OK  {0}" -f (Join-Path $out $nsis.Name)) -ForegroundColor Green
}
Write-Host "Double-click CursorVersionTool.exe to run (needs WebView2 on Windows)." -ForegroundColor DarkGray
