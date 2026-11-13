# 校验 Windows 产物是 GUI 子系统（IMAGE_SUBSYSTEM_WINDOWS_GUI = 2）。
#
# console 子系统（3）双击启动会分配一个黑窗，关窗即发 CTRL_CLOSE_EVENT 杀掉应用。
# 属性在 desktop/crates/app/src/main.rs 顶部（windows_subsystem），改丢/改错在这里拦下。
# 用法：pwsh -NoProfile -File scripts/verify-pe-subsystem.ps1 [exe 路径]
param([string]$Exe = "target/release/cgc-desktop-app.exe")

$ErrorActionPreference = "Stop"
if (-not (Test-Path $Exe)) { throw "FAIL: 找不到 $Exe" }

$stream = [System.IO.File]::OpenRead((Resolve-Path $Exe))
try {
    $reader = New-Object System.IO.BinaryReader($stream)
    $stream.Position = 0x3C
    $peOffset = $reader.ReadInt32()
    $stream.Position = $peOffset
    $signature = $reader.ReadUInt32()
    if ($signature -ne 0x00004550) { throw ("FAIL: PE 签名不是 PE\0\0（0x{0:X8}）" -f $signature) }
    # PE 签名(4) + COFF 头(20) + OptionalHeader；
    # Subsystem 在 OptionalHeader + 0x44（PE32 与 PE32+ 相同）=> e_lfanew + 0x5C。
    $stream.Position = $peOffset + 0x5C
    $subsystem = $reader.ReadUInt16()
} finally {
    $stream.Dispose()
}

Write-Host "PE subsystem = $subsystem"
if ($subsystem -ne 2) { throw "FAIL: PE subsystem 应为 2 (GUI)，实际 $subsystem" }
