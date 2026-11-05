# 校验 Windows 便携包（zip）「结构上可运行」。CI 与本地（Windows）共用。
# 未签名产物是预期状态（证书暂无，签名/公证归 epic-6），这里只记录不失败。
# 版本不在文件名里：从同名 .build.json 读，并断言与 CI 传的 VERSION/commit 一致。
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

$zip = Get-ChildItem -Path "dist" -Filter *.zip -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $zip) { throw "FAIL: desktop/dist 下没有 zip 产物" }
if ($zip.Name -notmatch '^cgc2046-windows-(x64|aarch64)\.zip$') {
  throw "FAIL: 产物名不符合 cgc2046-windows-<arch>.zip（实际 $($zip.Name)）；版本应写在同名 .build.json"
}
Write-Host "name ok: $($zip.Name)"

$metaPath = [System.IO.Path]::ChangeExtension($zip.FullName, ".build.json")
if (-not (Test-Path $metaPath)) { throw "FAIL: 缺构建元数据 $metaPath（版本/commit 只能从这里读）" }
$meta = Get-Content $metaPath -Raw | ConvertFrom-Json
foreach ($key in @("version", "sourceRevision", "platform", "arch")) {
  if (-not $meta.$key) { throw "FAIL: build.json 缺 $key" }
}
$wantVersion = $env:VERSION -replace '^desktop-v', ''
if ($wantVersion -and $meta.version -ne $wantVersion) { throw "FAIL: build.json version=$($meta.version) 与预期 $wantVersion 不一致" }
if ($env:CGC_BUILD_COMMIT -and $meta.sourceRevision -ne $env:CGC_BUILD_COMMIT) { throw "FAIL: build.json sourceRevision 与 CI commit 不一致" }
Write-Host "metadata ok: version=$($meta.version) commit=$($meta.sourceRevision)"

$tmp = Join-Path $env:TEMP ("cgc-zip-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  Expand-Archive -Path $zip.FullName -DestinationPath $tmp -Force

  # 必须在包根：用户按发布说明「解压后双击 cgc-desktop-app.exe」，递归找会掩盖
  # 「exe 埋在 PFiles/<程序名>/ 里」这种解压后看不到的问题。
  $exePath = Join-Path $tmp "cgc-desktop-app.exe"
  if (-not (Test-Path $exePath)) {
    throw "FAIL: cgc-desktop-app.exe 不在包根（解压后应直接看到它，实际顶层：$((Get-ChildItem $tmp | Select-Object -First 5 | ForEach-Object Name) -join ', ')）"
  }
  $exe = Get-Item $exePath
  # 便携包里不该出现 msi：administrative install 会把它复制进目标目录，混进来会让用户困惑。
  $strayMsi = Get-ChildItem -Path $tmp -Filter *.msi -Recurse -ErrorAction SilentlyContinue
  if ($strayMsi) { throw "FAIL: 便携包里混入 msi（$($strayMsi[0].Name)）" }

  # 端点断言（fail-closed）：Bearer token / 登录密码 / MCP lease token 都走这条通道，
  # 端点必须指向官方域。官方域是 codingirlsclub.com（曾拼错成 codinggirlsclub.com）。
  $text = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($exe.FullName))
  if (-not $text.Contains("https://api.codingirlsclub.com/api/graphql")) {
    throw "FAIL: 可执行文件缺官方端点（期望打包时注入 CGC_DEFAULT_API_URL=https://api.codingirlsclub.com/api/graphql）"
  }
  if ($text.Contains("codinggirlsclub.com/api")) {
    throw "FAIL: 可执行文件含错拼域 codinggirlsclub.com（官方域是 codingirlsclub.com）"
  }
  Write-Host "endpoint assertion ok"

  # DLL 依赖：便携包不解压安装，缺 DLL 会直接启动失败。
  $dlls = Get-ChildItem -Path (Split-Path -Parent $exe.FullName) -Filter *.dll -ErrorAction SilentlyContinue
  Write-Host "packaged dlls: $($dlls.Count)"
  Write-Host "zip ok; signature status: unsigned（预期，epic-6 接管签名）"
}
finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
