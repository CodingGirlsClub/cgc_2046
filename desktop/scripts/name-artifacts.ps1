# 安装包重命名（Windows 等价脚本，命名与 name-artifacts.sh 一致）。
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

$meta = cargo metadata --no-deps --format-version 1 | ConvertFrom-Json
$version = ($meta.packages | Where-Object { $_.name -eq "cgc-desktop-app" }).version
$commit = if ($env:CGC_BUILD_COMMIT) { $env:CGC_BUILD_COMMIT } else { (git rev-parse --short=7 HEAD) }
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "aarch64" } else { "x64" }

Get-ChildItem dist -File | Where-Object { $_.Extension -in ".dmg", ".msi", ".deb", ".AppImage", ".exe" } | ForEach-Object {
  $target = Join-Path "dist" "cgc2046_${version}_${commit}_${arch}$($_.Extension)"
  if ($_.FullName -ne (Resolve-Path $target -ErrorAction SilentlyContinue)) {
    Move-Item -Force $_.FullName $target
    Write-Host "renamed: $($_.Name) -> $(Split-Path -Leaf $target)"
  }
}
