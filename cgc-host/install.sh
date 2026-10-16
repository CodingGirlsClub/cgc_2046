#!/usr/bin/env bash
# cgc-host 安装与更新（R1、R2）：
#   macOS / Ubuntu：curl -fsSL https://api.codingirlsclub.com/ext/cgc-host/install.sh | bash
#   Windows：在 Git Bash（随 Git for Windows 安装）里执行同一条命令
# 重复执行即更新到最新版本，结果与装一次相同，始终只有一个登录自启项。
#
# 依次：把清单和包下载到临时目录，校验 sha256（失败即清理退出，不安装 Bun、不改旧 Host）
# → 查找 Bun，没有则用官方安装器装到 ~/.bun → 停掉旧 Host → 包落位、写当前系统的登录自启项 → 启动。
# 自启项里只有 Bun 与包的绝对路径，不含任何环境变量：OMP 的环境由 Host 运行时从学员的登录 shell 解析（KTD12）。
# 卸载命令在结束时打印：`<bun> ~/.cgc2046/host/cgc-host.js uninstall`，只在本机执行，平台连不上也能卸。
#
# 环境变量 CGC_HOST_DIST 覆盖下载地址（测试用）。它只决定从哪儿下载，包信任的站点来源与平台地址是构建时写死的（KTD4）。
set -euo pipefail

die() {
  echo "cgc-host: $*" >&2
  exit 1
}

# 整个流程包在函数里、最后一行才调用：curl | bash 半路断线时，半截脚本什么都不做
main() {
  local dist="${CGC_HOST_DIST:-https://api.codingirlsclub.com/ext/cgc-host}"
  local label=com.codingirlsclub.cgc-host
  # 与 src/uninstall.ts 删除的位置一一对应；状态目录同 src/state.ts 的 stateDir
  local host_dir="$HOME/.cgc2046/host"
  local os; os="$(uname -s)"
  local autostart log log_err=""
  case "$os" in
    Darwin)
      autostart="$HOME/Library/LaunchAgents/$label.plist"
      log="$HOME/Library/Logs/cgc-host.log"
      ;;
    Linux)
      # 图形确认弹窗（配对时用）与 systemd 用户服务是本系统分支的硬前提，缺了就地报错而不是装到一半
      command -v zenity >/dev/null || die "缺少图形确认工具，请先运行：sudo apt install zenity"
      command -v systemctl >/dev/null || die "需要 systemd 用户服务（Ubuntu 桌面默认具备）"
      autostart="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$label.service"
      log="${XDG_STATE_HOME:-$HOME/.local/state}/cgc-host.log"
      ;;
    MINGW* | MSYS* | CYGWIN*)
      command -v cygpath >/dev/null || die "请在 Git Bash（随 Git for Windows 安装）里运行这条命令"
      command -v powershell.exe >/dev/null || die "找不到 powershell.exe（Windows 自带）"
      autostart="$HOME/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup/CGC Host.cmd"
      log="$HOME/AppData/Local/CGC/cgc-host.log"
      log_err="$HOME/AppData/Local/CGC/cgc-host.error.log"
      ;;
    *) die "目前支持 macOS、Windows（Git Bash）与 Ubuntu 桌面" ;;
  esac

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$dist/cgc-host.json" -o "$tmp/cgc-host.json" || die "下载清单失败：$dist/cgc-host.json"
  curl -fsSL "$dist/cgc-host.js" -o "$tmp/cgc-host.js" || die "下载失败：$dist/cgc-host.js"
  # 清单只有三个字符串字段（deploy.yml 生成），不必为它引入 JSON 解析器
  local version sha256 actual
  version=$(sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$tmp/cgc-host.json")
  sha256=$(sed -nE 's/.*"sha256"[[:space:]]*:[[:space:]]*"([0-9a-f]{64})".*/\1/p' "$tmp/cgc-host.json")
  [ -n "$version" ] && [ -n "$sha256" ] || die "清单格式不对：$dist/cgc-host.json"
  # sha256sum 在 Ubuntu 是 coreutils、shasum 在 macOS/Git Bash 随 Perl 提供；先有的那个为准
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$tmp/cgc-host.js" | cut -d' ' -f1)
  else
    actual=$(shasum -a 256 "$tmp/cgc-host.js" | cut -d' ' -f1)
  fi
  [ "$actual" = "$sha256" ] || die "下载的包与清单的 sha256 不符，未安装 Bun，也未修改已有 Host，请稍后重试"

  # 校验通过后才允许安装依赖，失败的包不能在学员电脑上留下 ~/.bun。
  local bun
  bun=$(command -v bun || true)
  # 官方安装器装的 Bun 不一定已在当前 shell 的 PATH 里（Windows 上是 bun.exe）
  if [ -z "$bun" ] && [ -x "$HOME/.bun/bin/bun" ]; then bun="$HOME/.bun/bin/bun"; fi
  if [ -z "$bun" ] && [ -x "$HOME/.bun/bin/bun.exe" ]; then bun="$HOME/.bun/bin/bun.exe"; fi
  if [ -z "$bun" ]; then
    echo "Host 包已通过校验；没有找到 Bun，用官方安装器安装到 ~/.bun …"
    case "$os" in
      MINGW* | MSYS* | CYGWIN*) powershell.exe -NoProfile -Command "irm bun.sh/install.ps1 | iex" ;;
      *) curl -fsSL https://bun.sh/install | bash ;;
    esac
    if [ -x "$HOME/.bun/bin/bun" ]; then bun="$HOME/.bun/bin/bun"; else bun="$HOME/.bun/bin/bun.exe"; fi
    [ -x "$bun" ] || die "Bun 安装失败"
  fi

  # 先停旧的再启动新的，重复执行也只有一个自启项；没装过时停旧报错，无妨
  mkdir -p "$host_dir" "$(dirname "$autostart")" "$(dirname "$log")"
  chmod 700 "$host_dir" 2>/dev/null || true
  mv "$tmp/cgc-host.js" "$host_dir/cgc-host.js"
  case "$os" in
    Darwin)
      launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
      # KeepAlive 只在非 0 退出时拉起：端口被占（已有实例）时 Host 以 0 退出，不会被反复拉起
      cat >"$autostart" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$bun</string>
    <string>$host_dir/cgc-host.js</string>
    <string>serve</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>StandardOutPath</key>
  <string>$log</string>
  <key>StandardErrorPath</key>
  <string>$log</string>
</dict>
</plist>
EOF
      chmod 644 "$autostart"
      launchctl bootstrap "gui/$(id -u)" "$autostart"
      ;;
    Linux)
      systemctl --user disable --now "$label" >/dev/null 2>&1 || true
      cat >"$autostart" <<EOF
[Unit]
Description=CGC 本机 Host

[Service]
ExecStart="$bun" "$host_dir/cgc-host.js" serve
Restart=on-failure
RestartSec=30
StandardOutput="append:$log"
StandardError="append:$log"

[Install]
WantedBy=default.target
EOF
      systemctl --user daemon-reload
      systemctl --user enable --now "$label"
      ;;
    *)
      # 旧实例还在跑的话会占住端口、让新实例直接退出（更新不生效），先按命令行找到并停掉
      powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='bun.exe'\" | Where-Object { \$_.CommandLine -like '*cgc-host.js*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }" >/dev/null 2>&1 || true
      # 自启项：登录时经系统自带 PowerShell 隐藏拉起，日志重定向到文件；路径必须是 Windows 形式
      cat >"$autostart" <<EOF
@echo off
powershell -NoProfile -WindowStyle Hidden -Command "Start-Process -WindowStyle Hidden -FilePath '$(cygpath -w "$bun")' -ArgumentList '$(cygpath -w "$host_dir/cgc-host.js")','serve' -RedirectStandardOutput '$(cygpath -w "$log")' -RedirectStandardError '$(cygpath -w "$log_err")'"
EOF
      powershell.exe -NoProfile -WindowStyle Hidden -Command "& '$(cygpath -w "$autostart")'"
      ;;
  esac

  echo "cgc-host $version 已安装，正在后台运行，登录后会自动启动。回到课程学习页即可连接。"
  echo "日志：$log"
  printf '卸载：%q %q uninstall\n' "$bun" "$host_dir/cgc-host.js"
}

main "$@"
