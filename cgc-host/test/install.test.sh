#!/usr/bin/env bash
# cgc-host 安装、卸载与版本门禁测试（U7）：临时 HOME + PATH 垫片，不碰本机真实的 HOME 与 launchd。
#
# 覆盖：
#   1. 临时 HOME 下装两次，结果一致，只有一个 LaunchAgent（launchctl 垫片像 launchd 一样：已加载的再 bootstrap 就失败）
#   2. 校验和不符：安装中止，HOME 与临时目录里不写任何文件；已装的旧版原样在跑
#   3. plist 不含环境变量与凭证，权限 0644
#   4. 卸载（结束时打印的那条命令）：plist、包、状态目录与日志都不存在，课程工作目录原样保留；凭证经平台自撤销，不进 argv 与输出
#   5. 版本门禁：包内容变了而版本号没变必须失败；其余分支放行
#   6. 撤销接口不可达：卸载仍完成本地清理，并提示到「已配对的电脑」撤销
#   7. 无 Bun 的隔离 PATH：校验失败不调用安装器；校验成功才安装，已有 Bun 则复用
#
# 包按 deploy.yml 的方式构建（bun build --define），平台地址与下载地址都指向本测试起的本地服务器（端口由系统分配）。
# 运行：bash cgc-host/test/install.test.sh；退出码 0 = 全绿
set -euo pipefail

HOST_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
SERVER_PID=""
cleanup() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok() {
  local desc="$1"
  shift
  if "$@"; then
    echo "  ✓ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $desc"
    FAIL=$((FAIL + 1))
  fi
}
not() { ! "$@"; }
# GNU stat -f 失败时仍会输出文件系统信息，必须先试无此副作用的 GNU 格式。
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
is_mode() { [ "$(mode "$1")" = "$2" ]; }
is_empty_dir() { [ -d "$1" ] && [ -z "$(find "$1" -mindepth 1)" ]; }
# 目录树与每个文件的内容
snapshot() { (cd "$1" && find . | sort && find . -type f -exec shasum -a 256 {} + | sort); }

# ── 垫片：launchctl 记下调用并模拟 launchd 的加载状态；uname 让 Linux 上的 CI 也走 macOS 分支 ──
mkdir -p "$T/bin" "$T/www/ext/cgc-host"
export LAUNCHCTL_LOG="$T/launchctl.log" LAUNCHD="$T/launchd"
: >"$LAUNCHCTL_LOG"
: >"$LAUNCHD"
cat >"$T/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$LAUNCHCTL_LOG"
case "$1" in
  bootout)
    grep -qxF "$2" "$LAUNCHD" || { echo "Boot-out failed: 3: No such process" >&2; exit 3; }
    grep -vxF "$2" "$LAUNCHD" >"$LAUNCHD.tmp" || true
    mv "$LAUNCHD.tmp" "$LAUNCHD" ;;
  bootstrap)
    key="$2/$(basename "$3" .plist)"
    [ -f "$3" ] || { echo "Bootstrap failed: 2: No such file or directory" >&2; exit 2; }
    ! grep -qxF "$key" "$LAUNCHD" || { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
    echo "$key" >>"$LAUNCHD" ;;
esac
EOF
printf '#!/bin/sh\necho Darwin\n' >"$T/bin/uname"
chmod +x "$T/bin/launchctl" "$T/bin/uname"
SHIM_PATH="$T/bin:$PATH"

# ── 本地服务器：/ext/** 是下载目录，DELETE /mcp/token 记下出示的凭证（平台的自撤销接口） ──
cat >"$T/server.ts" <<'EOF'
const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  async fetch(req) {
    const { pathname } = new URL(req.url);
    if (req.method === "DELETE" && pathname === "/mcp/token") {
      await Bun.write(process.env.REVOKED!, req.headers.get("authorization") ?? "");
      return new Response(null, { status: 204 });
    }
    const file = Bun.file(process.env.WWW + pathname);
    return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
  },
});
console.log(server.port);
EOF
WWW="$T/www" REVOKED="$T/revoked" bun "$T/server.ts" >"$T/port" &
SERVER_PID=$!
for _ in $(seq 100); do [ -s "$T/port" ] && break; sleep 0.1; done
BASE="http://127.0.0.1:$(cat "$T/port")"

# ── 构建与发布：同 deploy.yml，只是平台地址换成本地服务器 ──
DIST="$T/www/ext/cgc-host"
(cd "$HOST_SRC" && bun build src/main.ts --target=bun --outfile="$DIST/cgc-host.js" \
  --define 'CGC_SITE_ORIGIN="https://codingirlsclub.com"' --define "CGC_API_BASE=\"$BASE\"" >/dev/null)
VERSION=$(bun -e "console.log((await Bun.file('$HOST_SRC/package.json').json()).version)")
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
manifest() { printf '{"version":"%s","download_path":"/ext/cgc-host/cgc-host.js","sha256":"%s"}' "$1" "$2"; }
manifest "$VERSION" "$(sha "$DIST/cgc-host.js")" >"$DIST/cgc-host.json"

# 在给定 HOME 下跑 install.sh；第二个参数覆盖下载地址
install_in() {
  mkdir -p "$1" "$T/tmp"
  env HOME="$1" TMPDIR="$T/tmp" PATH="$SHIM_PATH" CGC_HOST_DIST="${2:-$BASE/ext/cgc-host}" bash "$HOST_SRC/install.sh"
}
LABEL=com.codingirlsclub.cgc-host
DOMAIN="gui/$(id -u)"
TOKEN=cgch_test_secret_do_not_print
USER_ID=11111111-1111-4111-8111-111111111111
COURSE_ID=22222222-2222-4222-8222-222222222222
# 配对后的本机状态（同 src/state.ts）、一份作业，以及 launchd 写的日志
seed_paired() {
  mkdir -p "$1/.cgc2046/host" "$1/CGC/$USER_ID/$COURSE_ID" "$1/Library/Logs"
  printf '{"pairing":{"token":"%s","tokenId":"t1","userId":"%s","displayName":null,"maskedIdentifier":null,"browserKeyHash":"x"},"sessions":{}}' \
    "$TOKEN" "$USER_ID" >"$1/.cgc2046/host/state.json"
  echo "学员的作业" >"$1/CGC/$USER_ID/$COURSE_ID/homework.md"
  echo "cgc-host 0.1.0 在 127.0.0.1:47823 上监听" >"$1/Library/Logs/cgc-host.log"
}
# 跑安装输出里打印的那条卸载命令
uninstall_in() {
  local cmd
  cmd=$(sed -n 's/^卸载：//p' "$2")
  env HOME="$1" PATH="$SHIM_PATH" bash -c "$cmd"
}
assert_uninstalled() {
  ok "plist 已删除" not test -e "$1/Library/LaunchAgents/$LABEL.plist"
  ok "包与状态目录已删除" not test -e "$1/.cgc2046/host"
  ok "空的 ~/.cgc2046 一并删除" not test -e "$1/.cgc2046"
  ok "日志已删除" not test -e "$1/Library/Logs/cgc-host.log"
  ok "课程工作目录与作业原样保留" grep -qx "学员的作业" "$1/CGC/$USER_ID/$COURSE_ID/homework.md"
  ok "LaunchAgent 已 bootout" not grep -qxF "$DOMAIN/$LABEL" "$LAUNCHD"
}

echo "== 场景 1：装两次，结果一致，只有一个 LaunchAgent =="
H1="$T/h1"
install_in "$H1" >"$T/out1"
snapshot "$H1" >"$T/snap1"
rc=0
install_in "$H1" >"$T/out2" 2>&1 || rc=$?
snapshot "$H1" >"$T/snap2"
ok "第二次安装成功" [ "$rc" = 0 ]
ok "两次安装后文件树与内容一致" cmp -s "$T/snap1" "$T/snap2"
ok "LaunchAgents 下只有一个 plist" [ "$(find "$H1/Library/LaunchAgents" -type f | wc -l | tr -d ' ')" = 1 ]
ok "launchd 里只加载了一个 cgc-host" [ "$(cat "$LAUNCHD")" = "$DOMAIN/$LABEL" ]
ok "每次都先 bootout 再 bootstrap" [ "$(cut -d' ' -f1 "$LAUNCHCTL_LOG" | tr '\n' ' ')" = "bootout bootstrap bootout bootstrap " ]
ok "包与发布的一致" cmp -s "$H1/.cgc2046/host/cgc-host.js" "$DIST/cgc-host.js"
ok "状态目录 0700" is_mode "$H1/.cgc2046/host" 700
ok "临时目录已清理" is_empty_dir "$T/tmp"
ok "结束时打印卸载命令" grep -q "^卸载：.*cgc-host.js uninstall$" "$T/out2"

echo "== 场景 2：校验和不符即中止，不写入任何文件 =="
mkdir -p "$T/www/bad"
cp "$DIST/cgc-host.json" "$T/www/bad/"
{ cat "$DIST/cgc-host.js"; echo "// 被篡改"; } >"$T/www/bad/cgc-host.js"
H2="$T/h2"
calls=$(wc -l <"$LAUNCHCTL_LOG")
rc=0
install_in "$H2" "$BASE/bad" >"$T/out3" 2>&1 || rc=$?
ok "安装以非 0 退出" [ "$rc" != 0 ]
ok "提示 sha256 不符" grep -q "与清单的 sha256 不符" "$T/out3"
ok "HOME 里什么都没写" is_empty_dir "$H2"
ok "临时目录已清理" is_empty_dir "$T/tmp"
ok "没有调用 launchctl" [ "$(wc -l <"$LAUNCHCTL_LOG")" = "$calls" ]
rc=0
install_in "$H1" "$BASE/bad" >/dev/null 2>&1 || rc=$?
snapshot "$H1" >"$T/snap3"
ok "更新时校验失败：已装的旧版一字未动" cmp -s "$T/snap1" "$T/snap3"
ok "更新时校验失败：旧版仍在 launchd 里" [ "$(cat "$LAUNCHD")" = "$DOMAIN/$LABEL" ]

echo "== 场景 2b：无 Bun 时先校验，成功后才允许安装 Bun =="
# 只放安装脚本需要的系统工具，避免开发机 PATH 里的 Bun 让无 Bun 场景假绿。
NO_BUN_PATH="$T/no-bun-bin"
mkdir -p "$NO_BUN_PATH"
for tool in bash id mktemp rm sed cut mkdir dirname chmod mv cat grep basename; do
  ln -s "$(command -v "$tool")" "$NO_BUN_PATH/$tool"
done
ln -s "$T/bin/uname" "$NO_BUN_PATH/uname"
ln -s "$T/bin/launchctl" "$NO_BUN_PATH/launchctl"
export INSTALL_ORDER="$T/install-order" TEST_CURL="$(command -v curl)" TEST_SHASUM="$(command -v shasum)"
export TEST_BUN_INSTALLER="$T/bun-installer"
cat >"$TEST_BUN_INSTALLER" <<'EOF'
echo bun-installed >>"$INSTALL_ORDER"
mkdir -p "$HOME/.bun/bin"
printf '#!/bin/sh\nexit 0\n' >"$HOME/.bun/bin/bun"
chmod +x "$HOME/.bun/bin/bun"
EOF
cat >"$NO_BUN_PATH/curl" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    https://bun.sh/install)
      echo bun-installer-downloaded >>"$INSTALL_ORDER"
      cat "$TEST_BUN_INSTALLER"
      exit 0 ;;
    http://*/cgc-host.json) echo manifest >>"$INSTALL_ORDER" ;;
    http://*/cgc-host.js) echo bundle >>"$INSTALL_ORDER" ;;
  esac
done
exec "$TEST_CURL" "$@"
EOF
cat >"$NO_BUN_PATH/shasum" <<'EOF'
#!/usr/bin/env bash
echo checksum >>"$INSTALL_ORDER"
exec "$TEST_SHASUM" "$@"
EOF
chmod +x "$NO_BUN_PATH/curl" "$NO_BUN_PATH/shasum"
order_install_in() {
  mkdir -p "$1" "$T/order-tmp"
  env HOME="$1" TMPDIR="$T/order-tmp" PATH="${3:-$NO_BUN_PATH}" CGC_HOST_DIST="$2" \
    LAUNCHCTL_LOG="$T/order-launchctl" LAUNCHD="$T/order-launchd" bash "$HOST_SRC/install.sh"
}
: >"$T/order-launchctl"
: >"$T/order-launchd"
: >"$INSTALL_ORDER"
ok "隔离 PATH 中确实找不到 Bun" not env PATH="$NO_BUN_PATH" bash -c 'command -v bun'
H_NO_BUN="$T/no-bun-home"
rc=0
order_install_in "$H_NO_BUN" "$BASE/bad" >"$T/order-bad.out" 2>&1 || rc=$?
ok "无 Bun 且校验失败：以非 0 退出" [ "$rc" != 0 ]
ok "无 Bun 且校验失败：提示 sha256 不符" grep -q "与清单的 sha256 不符" "$T/order-bad.out"
ok "无 Bun 且校验失败：不下载或运行 Bun 安装器" not grep -q bun- "$INSTALL_ORDER"
ok "无 Bun 且校验失败：HOME 没有任何安装副作用" is_empty_dir "$H_NO_BUN"
ok "无 Bun 且校验失败：不调用 launchctl" not test -s "$T/order-launchctl"
ok "无 Bun 且校验失败：临时文件清理" is_empty_dir "$T/order-tmp"

H_OLD="$T/old-host-no-bun"
cp -R "$H1" "$H_OLD"
snapshot "$H_OLD" >"$T/order-old-before"
printf '%s\n' "$DOMAIN/$LABEL" >"$T/order-launchd"
: >"$INSTALL_ORDER"
rc=0
order_install_in "$H_OLD" "$BASE/bad" >"$T/order-old.out" 2>&1 || rc=$?
snapshot "$H_OLD" >"$T/order-old-after"
ok "旧 Host 缺 Bun 且校验失败：以非 0 退出" [ "$rc" != 0 ]
ok "旧 Host 缺 Bun 且校验失败：不调用 Bun 安装器" not grep -q bun- "$INSTALL_ORDER"
ok "旧 Host 缺 Bun 且校验失败：文件树与内容原样保留" cmp -s "$T/order-old-before" "$T/order-old-after"
ok "旧 Host 缺 Bun 且校验失败：LaunchAgent 原样运行" [ "$(cat "$T/order-launchd")" = "$DOMAIN/$LABEL" ]
ok "旧 Host 缺 Bun 且校验失败：不调用 launchctl" not test -s "$T/order-launchctl"
ok "旧 Host 缺 Bun 且校验失败：临时文件清理" is_empty_dir "$T/order-tmp"

H_NEW="$T/new-bun-home"
: >"$INSTALL_ORDER"
rc=0
order_install_in "$H_NEW" "$BASE/ext/cgc-host" >"$T/order-good.out" 2>&1 || rc=$?
ok "无 Bun 且校验成功：安装成功" [ "$rc" = 0 ]
ok "顺序为下载清单、下载包、校验，再下载并执行 Bun 安装器" \
  [ "$(tr '\n' ' ' <"$INSTALL_ORDER")" = "manifest bundle checksum bun-installer-downloaded bun-installed " ]
ok "Bun 落在隔离 HOME 内" test -x "$H_NEW/.bun/bin/bun"
ok "校验后的 Host 包正确落位" cmp -s "$H_NEW/.cgc2046/host/cgc-host.js" "$DIST/cgc-host.js"
ok "plist 使用新安装的 Bun" grep -qF "<string>$H_NEW/.bun/bin/bun</string>" "$H_NEW/Library/LaunchAgents/$LABEL.plist"
ok "成功安装后临时文件清理" is_empty_dir "$T/order-tmp"
snapshot "$H_NEW" >"$T/order-new-before"
: >"$INSTALL_ORDER"
rc=0
order_install_in "$H_NEW" "$BASE/ext/cgc-host" >"$T/order-repeat.out" 2>&1 || rc=$?
snapshot "$H_NEW" >"$T/order-new-after"
ok "Bun 仅在 ~/.bun 时重复安装成功" [ "$rc" = 0 ]
ok "复用 ~/.bun，不重复调用安装器" not grep -q bun- "$INSTALL_ORDER"
ok "重复安装文件树与内容一致" cmp -s "$T/order-new-before" "$T/order-new-after"

mkdir -p "$T/existing-bun-bin"
ln -s "$H_NEW/.bun/bin/bun" "$T/existing-bun-bin/bun"
: >"$INSTALL_ORDER"
H_PATH_BUN="$T/path-bun-home"
rc=0
order_install_in "$H_PATH_BUN" "$BASE/ext/cgc-host" "$T/existing-bun-bin:$NO_BUN_PATH" >"$T/order-path.out" 2>&1 || rc=$?
ok "PATH 已有 Bun 时安装成功" [ "$rc" = 0 ]
ok "PATH 已有 Bun 时不调用安装器" not grep -q bun- "$INSTALL_ORDER"
ok "PATH 已有 Bun 时不创建 ~/.bun" not test -e "$H_PATH_BUN/.bun"
ok "plist 使用 PATH 中的 Bun" grep -qF "<string>$T/existing-bun-bin/bun</string>" "$H_PATH_BUN/Library/LaunchAgents/$LABEL.plist"

echo "== 场景 3：plist 无密钥、权限 0644 =="
PLIST="$H1/Library/LaunchAgents/$LABEL.plist"
plist_has() {
  local after
  after=$(grep -A"$1" "<key>$2</key>" "$PLIST")
  [[ "$after" == *"$3"* ]]
}
ok "权限 0644" is_mode "$PLIST" 644
ok "不含 EnvironmentVariables" not grep -q EnvironmentVariables "$PLIST"
ok "不含凭证" not grep -qi "cgch_\|token\|secret\|password" "$PLIST"
ok "ProgramArguments 是 Bun、包的绝对路径与 serve" grep -qF "<string>$H1/.cgc2046/host/cgc-host.js</string>" "$PLIST"
ok "第一个参数是 Bun 的绝对路径" grep -qF "<string>$(command -v bun)</string>" "$PLIST"
ok "RunAtLoad" plist_has 1 RunAtLoad "<true/>"
ok "KeepAlive 只在非 0 退出时拉起" plist_has 3 KeepAlive "<key>SuccessfulExit</key>"
ok "KeepAlive.SuccessfulExit 为 false" plist_has 1 SuccessfulExit "<false/>"
ok "ThrottleInterval 30" plist_has 1 ThrottleInterval "<integer>30</integer>"
ok "日志写到 ~/Library/Logs/" [ "$(grep -c "<string>$H1/Library/Logs/cgc-host.log</string>" "$PLIST")" = 2 ]
if command -v plutil >/dev/null; then ok "plutil -lint 通过" plutil -lint -s "$PLIST"; fi

echo "== 场景 4：卸载删干净、保留作业，凭证自撤销且不外泄 =="
seed_paired "$H1"
rc=0
uninstall_in "$H1" "$T/out2" >"$T/out4" 2>&1 || rc=$?
ok "卸载成功" [ "$rc" = 0 ]
assert_uninstalled "$H1"
ok "向平台出示这枚凭证自撤销" [ "$(cat "$T/revoked")" = "Bearer $TOKEN" ]
ok "凭证不进输出" not grep -q "$TOKEN" "$T/out4"
ok "凭证不进 launchctl 的 argv" not grep -q "$TOKEN" "$LAUNCHCTL_LOG"
ok "撤销成功时不提示手动撤销" not grep -q "已配对的电脑" "$T/out4"

echo "== 场景 5：版本门禁 =="
GATE="$T/www/gate"
mkdir -p "$GATE"
{ cat "$DIST/cgc-host.js"; echo "// 内容变了"; } >"$T/changed.js"
gate() { env CGC_HOST_MANIFEST_URL="$BASE/gate/cgc-host.json" bun "$HOST_SRC/scripts/check-version-bump.ts" "$@"; }
gate_rc() {
  local rc=0
  gate "$@" >"$T/gate.out" 2>&1 || rc=$?
  echo "$rc"
}
gate_warns() { [ "$(gate_rc "$@")" = 0 ] && grep -q "WARN" "$T/gate.out"; }
manifest "$VERSION" "$(sha "$DIST/cgc-host.js")" >"$GATE/cgc-host.json"
ok "内容没变：放行" [ "$(gate_rc "$DIST/cgc-host.js")" = 0 ]
ok "内容变了、版本号没变：失败" [ "$(gate_rc "$T/changed.js")" = 1 ]
ok "失败时说明要提高版本号" grep -q "版本号没变" "$T/gate.out"
manifest "0.0.0" "$(sha "$DIST/cgc-host.js")" >"$GATE/cgc-host.json"
ok "内容变了、版本号也变了：放行" [ "$(gate_rc "$T/changed.js")" = 0 ]
echo '{"version":"0.1.0"}' >"$GATE/cgc-host.json"
ok "线上清单畸形：拒绝发布" [ "$(gate_rc "$T/changed.js")" = 1 ]
rm "$GATE/cgc-host.json"
ok "线上还没有清单（首次发布）：警告并放行" gate_warns "$T/changed.js"
ok "不给包路径：用法错误" [ "$(gate_rc)" = 2 ]

echo "== 场景 5b：Ubuntu 分支（uname 报 Linux；zenity/systemctl 垫片） =="
LINUX_BIN="$T/bin-linux"; mkdir -p "$LINUX_BIN"
printf '#!/bin/sh\necho Linux\n' >"$LINUX_BIN/uname"
printf '#!/bin/sh\nexit 1\n' >"$LINUX_BIN/zenity"
cat >"$LINUX_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$SYSTEMCTL_LOG"
EOF
chmod +x "$LINUX_BIN"/*
export SYSTEMCTL_LOG="$T/systemctl.log"
LINUX_PATH="$LINUX_BIN:$NO_BUN_PATH" # NO_BUN_PATH 保证找不到 Bun，并只放安装脚本需要的系统工具
install_linux() { # HOME 为 $1；XDG 目录固定到 HOME 之下，断言与机器环境无关
  env HOME="$1" TMPDIR="$T/tmp" PATH="$LINUX_PATH" XDG_CONFIG_HOME="$1/udg-config" XDG_STATE_HOME="$1/udg-state" \
    CGC_HOST_DIST="${2:-$BASE/ext/cgc-host}" bash "$HOST_SRC/install.sh"
}
H4="$T/h4"
mkdir -p "$H4/.bun/bin"; printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v bun)" >"$H4/.bun/bin/bun"; chmod +x "$H4/.bun/bin/bun"
: >"$SYSTEMCTL_LOG"
rc=0
install_linux "$H4" >"$T/out-linux" 2>&1 || rc=$?
UNIT="$H4/udg-config/systemd/user/$LABEL.service"
ok "Linux：第一次安装成功" [ "$rc" = 0 ]
ok "Linux：systemd 用户服务已写入" test -f "$UNIT"
ok "Linux：ExecStart 指向 Bun 与包的绝对路径加 serve" grep -qF "ExecStart=\"$H4/.bun/bin/bun\" \"$H4/.cgc2046/host/cgc-host.js\" serve" "$UNIT"
ok "Linux：异常才重启（对齐 plist 的 KeepAlive SuccessfulExit=false）" grep -qxF "Restart=on-failure" "$UNIT"
ok "Linux：日志 append 到 XDG_STATE_HOME" grep -qF "StandardOutput=\"append:$H4/udg-state/cgc-host.log\"" "$UNIT"
ok "Linux：服务里不含环境变量（OMP 环境由登录 shell 解析）" not grep -q Environment "$UNIT"
ok "Linux：先 disable --now，再 daemon-reload 与 enable --now" [ "$(tr '\n' ' ' <"$SYSTEMCTL_LOG")" = "systemctl --user disable --now $LABEL systemctl --user daemon-reload systemctl --user enable --now $LABEL " ]
ok "Linux：日志目录已建" test -d "$H4/udg-state"
snapshot "$H4" >"$T/snap-h4a"
install_linux "$H4" >"$T/out-linux2" 2>&1
snapshot "$H4" >"$T/snap-h4b"
ok "Linux：重复安装结果与装一次相同" cmp -s "$T/snap-h4a" "$T/snap-h4b"
H4X="$T/h4x"; mkdir -p "$H4X/.bun/bin"; printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v bun)" >"$H4X/.bun/bin/bun"; chmod +x "$H4X/.bun/bin/bun"
LINUX_NOZENITY="$T/bin-linux-nozenity"; mkdir -p "$LINUX_NOZENITY"
printf '#!/bin/sh\necho Linux\n' >"$LINUX_NOZENITY/uname"
chmod +x "$LINUX_NOZENITY/uname"
rc=0
env HOME="$H4X" TMPDIR="$T/tmp" PATH="$LINUX_NOZENITY:$NO_BUN_PATH" XDG_CONFIG_HOME="$H4X/udg-config" CGC_HOST_DIST="$BASE/ext/cgc-host" bash "$HOST_SRC/install.sh" >"$T/out-linux-nozenity" 2>&1 || rc=$?
ok "Linux：缺 zenity 时明确报错并中止" [ "$rc" != 0 ] && grep -q "apt install zenity" "$T/out-linux-nozenity"
ok "Linux：缺 zenity 时不写任何文件" not test -e "$H4X/.cgc2046" && not test -e "$H4X/udg-config"
cmd=$(sed -n 's/^卸载：//p' "$T/out-linux2")
env HOME="$H4" PATH="$LINUX_PATH" XDG_CONFIG_HOME="$H4/udg-config" XDG_STATE_HOME="$H4/udg-state" bash -c "$cmd" >"$T/out-linux-rm" 2>&1
ok "Linux：卸载删除自启服务与日志" not test -e "$UNIT" && not test -e "$H4/udg-state/cgc-host.log"
ok "Linux：卸载删除包与状态目录" not test -e "$H4/.cgc2046/host"

echo "== 场景 5c：Windows 分支（Git Bash 垫片：uname 报 MINGW、cygpath、powershell.exe） =="
WIN_BIN="$T/bin-win"; mkdir -p "$WIN_BIN"
printf '#!/bin/sh\necho MINGW64_NT-10.0\n' >"$WIN_BIN/uname"
cat >"$WIN_BIN/cygpath" <<'EOF'
#!/bin/sh
# 垫片：-w 时原样返回最后一个参数（测试只断言路径出现在生成内容里）
for last in "$@"; do :; done
printf '%s' "$last"
EOF
cat >"$WIN_BIN/powershell.exe" <<'EOF'
#!/usr/bin/env bash
echo "powershell $*" >>"$POWERSHELL_LOG"
EOF
chmod +x "$WIN_BIN"/*
export POWERSHELL_LOG="$T/powershell.log"
WIN_PATH="$WIN_BIN:$NO_BUN_PATH"
install_windows() {
  env HOME="$1" TMPDIR="$T/tmp" PATH="$WIN_PATH" CGC_HOST_DIST="${2:-$BASE/ext/cgc-host}" bash "$HOST_SRC/install.sh"
}
H5="$T/h5"
mkdir -p "$H5/.bun/bin"; printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v bun)" >"$H5/.bun/bin/bun.exe"; chmod +x "$H5/.bun/bin/bun.exe"
: >"$POWERSHELL_LOG"
rc=0
install_windows "$H5" >"$T/out-win" 2>&1 || rc=$?
CMD5="$H5/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup/CGC Host.cmd"
ok "Windows：第一次安装成功" [ "$rc" = 0 ]
ok "Windows：自启 .cmd 已写入 Startup（$HOME 映射的路径）" test -f "$CMD5"
ok "Windows：经系统自带 PowerShell 隐藏启动" grep -q "Start-Process -WindowStyle Hidden" "$CMD5"
ok "Windows：stdout 与 stderr 分别重定向到日志" grep -q "cgc-host.log" "$CMD5" && grep -q "cgc-host.error.log" "$CMD5"
ok "Windows：安装时先停旧实例（按命令行 Stop-Process）" grep -q "Stop-Process" "$POWERSHELL_LOG"
ok "Windows：安装后立即拉起一次" grep -q "& '" "$POWERSHELL_LOG"
ok "Windows：日志目录已建" test -d "$H5/AppData/Local/CGC"
snapshot "$H5" >"$T/snap-h5a"
install_windows "$H5" >"$T/out-win2" 2>&1
snapshot "$H5" >"$T/snap-h5b"
ok "Windows：重复安装结果与装一次相同" cmp -s "$T/snap-h5a" "$T/snap-h5b"
cmd=$(sed -n 's/^卸载：//p' "$T/out-win2")
env HOME="$H5" PATH="$WIN_PATH" bash -c "$cmd" >"$T/out-win-rm" 2>&1
ok "Windows：卸载删除 Startup 自启项" not test -e "$CMD5"
ok "Windows：卸载删除日志目录与包" not test -e "$H5/AppData/Local/CGC" && not test -e "$H5/.cgc2046/host"

echo "== 场景 6：撤销接口不可达，卸载仍完成本地清理并提示 =="
H3="$T/h3"
install_in "$H3" >"$T/out5"
seed_paired "$H3"
kill "$SERVER_PID"
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
rc=0
uninstall_in "$H3" "$T/out5" >"$T/out6" 2>&1 || rc=$?
ok "卸载成功" [ "$rc" = 0 ]
assert_uninstalled "$H3"
ok "提示到「已配对的电脑」撤销这台电脑" grep -q "已配对的电脑" "$T/out6"
ok "凭证不进输出" not grep -q "$TOKEN" "$T/out6"
ok "版本门禁：线上不可达拒绝发布" [ "$(gate_rc "$T/changed.js")" = 1 ]

echo ""
echo "== 结果：$PASS 通过，$FAIL 失败 =="
[ "$FAIL" -eq 0 ]
