# 校验 Windows MSI「结构上可安装」。CI 与本地（Windows）共用。
# 未签名产物是预期状态（证书暂无，签名/公证归 epic-6），这里只记录不失败。
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

$msi = Get-ChildItem -Path "dist" -Filter *.msi -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $msi) { throw "FAIL: desktop/dist 下没有 msi 产物" }

$tmp = Join-Path $env:TEMP ("cgc-msi-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $args = @("/a", "`"$($msi.FullName)`"", "/qn", "TARGETDIR=`"$tmp`"")
  $p = Start-Process msiexec.exe -ArgumentList $args -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "msiexec /a 失败，exit=$($p.ExitCode)" }

  $exe = Get-ChildItem -Path $tmp -Recurse -Filter "cgc-desktop-app.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $exe) { throw "administrative install 后找不到 cgc-desktop-app.exe" }

  $sig = Get-AuthenticodeSignature $msi.FullName
  Write-Host "msi ok; signature status: $($sig.Status)（unsigned 预期，epic-6 接管签名）"
}
finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
