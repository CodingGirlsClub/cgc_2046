# 便携包的用户级 cgc:// 协议注册（Windows）。解压后运行一次即可，不需要管理员权限。
#
# 为什么要单独一步：`desktop/crates/app/Cargo.toml` 把协议注册交给安装器
# （[[package.metadata.packager.deepLinkProtocols]]，写 MSI 注册表），而 zip 便携包
# 不经过安装器——不注册的话，从网页点 cgc:// 深链系统不知道该用哪个程序打开。
# 这里只写当前用户（HKCU\Software\Classes\cgc），不影响系统级配置。
$ErrorActionPreference = "Stop"

$exe = Get-ChildItem -Path $PSScriptRoot -Recurse -Filter "cgc-desktop-app.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $exe) { throw "FAIL: 找不到 cgc-desktop-app.exe" }

$root = "HKCU:\Software\Classes\cgc"
New-Item -Path $root -Force | Out-Null
Set-ItemProperty -Path $root -Name "(Default)" -Value "URL:CGC 深链"
Set-ItemProperty -Path $root -Name "URL Protocol" -Value ""

New-Item -Path "$root\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "$root\shell\open\command" -Name "(Default)" -Value "`"$($exe.FullName)`" `"%1`""

Write-Host "registered: HKCU\Software\Classes\cgc -> $($exe.FullName)"
Write-Host "done. 现在从网页点击 cgc:// 链接应由 cgc-desktop-app.exe 接管。"
Write-Host "撤销：Remove-Item -Recurse 'HKCU:\Software\Classes\cgc'"
