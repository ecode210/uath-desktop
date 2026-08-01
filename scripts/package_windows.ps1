# Build and package UATH NFC Bridge for Windows.
# Run from a Windows machine (or CI) with Flutter + Visual Studio desktop workload.
# Output: dist\UATH-NFC-Bridge-windows-<version>.zip
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$Version = (Select-String -Path "pubspec.yaml" -Pattern "^version:\s*([^\+]+)").Matches[0].Groups[1].Value.Trim()
$OutDir = Join-Path $Root "dist"
$Stage = Join-Path $OutDir "windows_stage"
$ZipPath = Join-Path $OutDir "UATH-NFC-Bridge-windows-$Version.zip"

Write-Host "==> flutter build windows --release"
flutter build windows --release

$ReleaseDir = Join-Path $Root "build\windows\x64\runner\Release"
if (-not (Test-Path $ReleaseDir)) {
  throw "Expected release folder at $ReleaseDir"
}

if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Force -Path $Stage | Out-Null
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$AppFolder = Join-Path $Stage "UATH NFC Bridge"
Copy-Item -Recurse $ReleaseDir $AppFolder

# Prefer a clear exe name for end users (Flutter keeps the package name by default).
$BuiltExe = Join-Path $AppFolder "uath_desktop.exe"
$FriendlyExe = Join-Path $AppFolder "UATH NFC Bridge.exe"
if ((Test-Path $BuiltExe) -and -not (Test-Path $FriendlyExe)) {
  Rename-Item $BuiltExe "UATH NFC Bridge.exe"
}

if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }
Compress-Archive -Path $AppFolder -DestinationPath $ZipPath -Force

Remove-Item -Recurse -Force $Stage

Write-Host ""
Write-Host "Windows package ready:"
Write-Host "  $ZipPath"
Write-Host ""
Write-Host "Install: unzip anywhere, run `"UATH NFC Bridge.exe`"."
Write-Host "Keep the whole folder together (DLLs + data next to the exe)."
