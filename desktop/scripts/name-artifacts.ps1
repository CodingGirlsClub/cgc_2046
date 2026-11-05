# 安装包重命名 + 构建元数据（Windows 等价脚本，命名与 name-artifacts.sh 一致）。
# 文件名不带版本（版本由 tag 承载），版本/commit/签名状态写进同名 .build.json。
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

$meta = cargo metadata --no-deps --format-version 1 | ConvertFrom-Json
$version = if ($env:VERSION) { $env:VERSION } else { ($meta.packages | Where-Object { $_.name -eq "cgc-desktop-app" }).version }
$commit = if ($env:CGC_BUILD_COMMIT) { $env:CGC_BUILD_COMMIT } else { (git rev-parse --short=7 HEAD) }
$releaseTag = if ($env:CGC_RELEASE_TAG) { $env:CGC_RELEASE_TAG } else { $null }
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "aarch64" } else { "x64" }

Get-ChildItem dist -File | Where-Object { $_.Extension -in ".zip", ".msi" } | ForEach-Object {
  $ext = $_.Extension.TrimStart(".")
  $target = Join-Path "dist" "cgc2046-windows-${arch}.${ext}"
  if ($_.FullName -ne $target) {
    Move-Item -Force $_.FullName $target
    Write-Host "renamed: $($_.Name) -> $(Split-Path -Leaf $target)"
  }

  $metaPath = Join-Path "dist" "cgc2046-windows-${arch}.build.json"
  $payload = [ordered]@{
    schemaVersion  = 1
    product        = "cgc2046"
    version        = $version
    releaseTag     = $releaseTag
    sourceRevision = $commit
    platform       = "windows"
    arch           = $arch
    signing        = "unsigned"
    notarized      = $false
  }
  ($payload | ConvertTo-Json) + "`n" | Set-Content -NoNewline -Encoding utf8 $metaPath
  Write-Host "metadata: $(Split-Path -Leaf $metaPath)"
}
