#!/usr/bin/env bash
# cgc-host 安装与更新（R1、R2）：
#   curl -fsSL https://api.codingirlsclub.com/ext/cgc-host/install.sh | bash
# 重复执行即更新到最新版本，结果与装一次相同，始终只有一个 LaunchAgent。
#
# 依次：把清单和包下载到临时目录，校验 sha256（失败即清理退出，不安装 Bun、不改旧 Host）
# → 查找 Bun，没有则用官方安装器装到 ~/.bun → 停掉旧 Host → 包落位、写 LaunchAgent plist → 启动。
# plist 里只有 Bun 与包的绝对路径，不含任何环境变量：OMP 的环境由 Host 运行时从学员的登录 shell 解析（KTD12）。
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
  local plist="$HOME/Library/LaunchAgents/$label.plist"
  local log="$HOME/Library/Logs/cgc-host.log"
  local domain
  domain="gui/$(id -u)"

  [ "$(uname -s)" = Darwin ] || die "目前只支持 macOS"

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$dist/cgc-host.json" -o "$tmp/cgc-host.json" || die "下载清单失败：$dist/cgc-host.json"
  curl -fsSL "$dist/cgc-host.js" -o "$tmp/cgc-host.js" || die "下载失败：$dist/cgc-host.js"
  # 清单只有三个字符串字段（deploy.yml 生成），不必为它引入 JSON 解析器
  local version sha256 actual
  version=$(sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$tmp/cgc-host.json")
  sha256=$(sed -nE 's/.*"sha256"[[:space:]]*:[[:space:]]*"([0-9a-f]{64})".*/\1/p' "$tmp/cgc-host.json")
  [ -n "$version" ] && [ -n "$sha256" ] || die "清单格式不对：$dist/cgc-host.json"
  actual=$(shasum -a 256 "$tmp/cgc-host.js" | cut -d' ' -f1)
  [ "$actual" = "$sha256" ] || die "下载的包与清单的 sha256 不符，未安装 Bun，也未修改已有 Host，请稍后重试"

  # 校验通过后才允许安装依赖，失败的包不能在学员电脑上留下 ~/.bun。
  local bun
  bun=$(command -v bun || true)
  # 官方安装器装的 Bun 不一定已在当前 shell 的 PATH 里
  if [ -z "$bun" ] && [ -x "$HOME/.bun/bin/bun" ]; then bun="$HOME/.bun/bin/bun"; fi
  if [ -z "$bun" ]; then
    echo "Host 包已通过校验；没有找到 Bun，用官方安装器安装到 ~/.bun …"
    curl -fsSL https://bun.sh/install | bash
    bun="$HOME/.bun/bin/bun"
    [ -x "$bun" ] || die "Bun 安装失败"
  fi

  # 先停旧的再启动新的，重复执行也只有一个 LaunchAgent；没装过时 bootout 报错，无妨
  launchctl bootout "$domain/$label" 2>/dev/null || true
  mkdir -p "$host_dir" "$(dirname "$plist")" "$(dirname "$log")"
  chmod 700 "$host_dir"
  mv "$tmp/cgc-host.js" "$host_dir/cgc-host.js"
  # KeepAlive 只在非 0 退出时拉起：端口被占（已有实例）时 Host 以 0 退出，不会被反复拉起
  cat >"$plist" <<EOF
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
  chmod 644 "$plist"
  launchctl bootstrap "$domain" "$plist"

  echo "cgc-host $version 已安装，正在后台运行，开机后会自动启动。回到课程学习页即可连接。"
  echo "日志：$log"
  printf '卸载：%q %q uninstall\n' "$bun" "$host_dir/cgc-host.js"
}

main "$@"
