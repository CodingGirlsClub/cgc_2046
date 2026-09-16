#!/usr/bin/env bash
# Initiative 旅程 E2E（小程序 / weapp 模拟器，本地回归用，**不进 CI**）
#
# 覆盖（对齐 web /initiatives/[slug] + /events/[slug] 的公开面）：
#   1. 发现页倡导活动卡片可达（#577 公开链接可达）
#   2. 倡导活动详情：标题 / 城市分组 / 场次卡的公开事实（地点、报名截止、成班徽章）
#   3. 场次卡 → 活动详情：**「所属倡导活动」回链**（本次新增）+ 成班徽章口径
#   4. 回链 → 回到倡导活动详情（分享进来的用户能回到 campaign 页）
#   5. 回归：badge=open 的场次不渲染成班徽章；未挂载 Initiative 的场次不渲染回链
#
# 为什么不在 CI：需要微信开发者工具 GUI（已登录）+ wechatide CLI，见
# miniprogram/AGENTS.md「E2E」一节。web 端 E2E 走 ego-browser，与本脚本无关。
#
# 前置：
#   1. 微信开发者工具已安装并已登录；`wechatide` 在 PATH（本机 ~/.local/bin/wechatide）
#   2. 首次调用 wechatide 会在工具内弹授权窗，需人工点同意（client 名 = CLIENT）
#   3. wechatide-skill 已装在 `.agents/skills/wechatide-skill`
#
# 用法：pnpm e2e:initiative   （或 bash e2e/initiative-journey.e2e.sh）
#
# 选择器纪律：Taro 4 weapp 运行时**不把 data-testid 渲染进 WXML**（渲染树只有
# id/class/data-sid，见 #579），所以本脚本一律用 CSS-module 类名。哈希随样式变，
# 故运行时从 dist 产物里解析，不写死。另：wechatide 的 --wait-for-selector 是
# 「执行**前**等待」，用它等本步要操作的元素，不要当导航后的等待用。
set -uo pipefail

CLIENT="${CGC_WECHATIDE_CLIENT:-DSH}"
MP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$MP_DIR/dist/weapp"
PASS=0
FAIL=0

command -v wechatide >/dev/null || {
  echo "✗ 找不到 wechatide CLI。需安装微信开发者工具（含 wechatide），" >&2
  echo "  或在 PATH 上补软链；详见 miniprogram/AGENTS.md「E2E」一节。" >&2
  exit 2
}

# 缺依赖时别让它以「mock 构建失败」的面目出现（看不出真实原因）：Paseo 建的 worktree
# 由 setup 自动装（paseo.json），手工 `git worktree add` 或早于该 setup 的 worktree 需自己装
[ -x "$MP_DIR/node_modules/.bin/taro" ] || {
  echo "✗ 缺小程序依赖（$MP_DIR/node_modules）。" >&2
  echo "  先执行：cd miniprogram && pnpm install --frozen-lockfile" >&2
  echo "  注：Paseo 建的 worktree 由 paseo.json 的 setup 自动安装；手工创建的需自己装。" >&2
  exit 2
}

RAW() { timeout 120 wechatide -c "$CLIENT" "$@" --project "$MP_DIR" 2>&1; }
# 取 toolCall 结果里的字符串值（text / property 类读取）
RES() { RAW "$@" | sed -n 's/.*"result": "\(.*\)"/\1/p' | tail -1; }
TAP() { RAW automation_element_action --selector "$1" --action tap --wait-for-selector "$1" >/dev/null; }
ROUTE() { RAW automation_runtime_info --action currentPage | grep -o '"route": "[^"]*"' | head -1; }
COUNT() { RAW automation_page_action --action querySelectorAll --selector "$1" | grep -c elementId; }
ck() {
  if printf '%s' "$2" | grep -Eq "$3"; then
    echo "  ✅ $1"; PASS=$((PASS + 1))
  else
    echo "  ❌ $1"; echo "     实际: [$2]"; echo "     期望匹配: $3"; FAIL=$((FAIL + 1))
  fi
}
wait_route() {
  for _ in $(seq 1 25); do case "$(ROUTE)" in *"$1"*) return 0 ;; esac; sleep 1; done
  return 1
}
# CSS-module 类名（哈希运行时解析）：cls <pages/xxx> <className>
cls() {
  local hit
  hit="$(grep -o "index-module__$2___[A-Za-z0-9_]*" "$DIST/$1/index.wxss" 2>/dev/null | head -1)"
  [ -n "$hit" ] || { echo "✗ 构建产物里找不到类名 $2（$1）——样式改动后请重跑 mock 构建" >&2; exit 2; }
  printf '.%s' "$hit"
}

restore() {
  echo "→ 还原非 mock 构建"
  (cd "$MP_DIR" && ./node_modules/.bin/taro build --type weapp >/dev/null 2>&1) || true
}
trap restore EXIT

echo "→ mock 构建 weapp（E2E 走 mock transport，不碰真后端）"
(cd "$MP_DIR" && CGC_E2E_MOCK=true ./node_modules/.bin/taro build --type weapp >/dev/null 2>&1) || {
  echo "✗ mock 构建失败" >&2; exit 2
}

echo "→ 打开项目窗口（已开则复用）"
RAW open_project_window >/dev/null

DISCOVER='pages/discover'
INITIATIVE='pages/initiative-detail'
EVENT='pages/event-detail'

INITIATIVE_CARD=$(cls "$DISCOVER" initiativeCard)
INIT_TITLE=$(cls "$INITIATIVE" title)
INIT_CITY=$(cls "$INITIATIVE" city)
INIT_EVENT_CARD=$(cls "$INITIATIVE" card)
BACKLINK=$(cls "$EVENT" initiativeLink)
BADGE=$(cls "$EVENT" qualificationBadge)
EVENT_TITLE=$(cls "$EVENT" title)

echo "### 1) 发现页 → 倡导活动卡片 → 详情（公开链接可达，mock: initiative-1 / python-1024）"
RAW automation_navigate --action reLaunch --url '/pages/discover/index' >/dev/null
sleep 2
ck "发现页有倡导活动卡片" "$(COUNT "$INITIATIVE_CARD")" '^1$'
TAP "$INITIATIVE_CARD"
wait_route '/pages/initiative-detail/index' || true
ck "落在倡导活动详情" "$(ROUTE)" '/pages/initiative-detail/index'

echo "### 2) 倡导活动详情：标题 / 城市分组 / 场次的公开事实"
ck "活动名" "$(RES automation_element_action --action text --selector "$INIT_TITLE")" '1024 程序员节'
ck "城市分组存在" "$(COUNT "$INIT_CITY")" '^1$'
ck "场次卡：成班徽章（与 web initiatives.shortBy 同口径）" \
  "$(RES automation_element_action --action text --selector "$INIT_EVENT_CARD")" '还差 3 人成班'
ck "场次卡：地点" \
  "$(RES automation_element_action --action text --selector "$INIT_EVENT_CARD")" '地点：中国 北京市 北京 海淀区'
ck "场次卡：报名截止" \
  "$(RES automation_element_action --action text --selector "$INIT_EVENT_CARD")" '报名截止：'

echo "### 3) 场次卡 → 活动详情：「所属倡导活动」回链"
TAP "$INIT_EVENT_CARD"
wait_route '/pages/event-detail/index' || true
ck "落在活动详情" "$(ROUTE)" '/pages/event-detail/index'
ck "活动标题" "$(RES automation_element_action --action text --selector "$EVENT_TITLE")" 'Python 入门工作坊'
ck "回链文案" \
  "$(RES automation_element_action --action text --selector "$BACKLINK")" '所属倡导活动：1024 程序员节'
ck "详情页成班徽章" \
  "$(RES automation_element_action --action text --selector "$BADGE")" '还差 3 人成班'

echo "### 4) 回链 → 回到倡导活动详情（分享进来的用户可回到 campaign 页）"
TAP "$BACKLINK"
wait_route '/pages/initiative-detail/index' || true
ck "回链回到倡导活动" "$(ROUTE)" '/pages/initiative-detail/index'
ck "回到的是同一个活动" "$(RES automation_element_action --action text --selector "$INIT_TITLE")" '1024 程序员节'

echo "### 5) 回归：open 徽章不渲染；未挂载 Initiative 的场次无回链（mock: event-open）"
RAW automation_navigate --action reLaunch --url '/pages/event-detail/index?id=event-open&kind=event' >/dev/null
sleep 2
ck "落在 event-open 详情" "$(ROUTE)" '/pages/event-detail/index'
ck "badge=open 不渲染成班徽章" "$(COUNT "$BADGE")" '^0$'
ck "未挂载场次不渲染回链" "$(COUNT "$BACKLINK")" '^0$'

echo "### 6) 截图取证（给人看；脚本本身不做视觉判定）"
SHOT="${TMPDIR:-/tmp}/initiative-journey.png"
if RAW simulator_screenshot --path "$SHOT" | grep -q '"success": true'; then
  echo "  📸 $SHOT"
else
  echo "  ⚠️ 截图失败（不影响断言结论）"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "=== E2E PASS: $PASS/$PASS ==="
else
  echo "=== E2E FAIL: PASS=$PASS FAIL=$FAIL ==="
fi
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
