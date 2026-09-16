#!/usr/bin/env bash
# 押金同意门 E2E（小程序 / weapp 模拟器，本地回归用，**不进 CI**）
#
# 覆盖：押金单在 order-pay 的「资金动作前披露 + 显式同意」——披露口径与金额、
# 未勾选禁用、勾选后放行。这是 #544 第 2 项 + U1 小程序落点的回归网。
#
# 为什么不在 CI：需要微信开发者工具 GUI（已登录）+ wechatide CLI（随工具分发），
# 见 miniprogram/AGENTS.md「E2E」一节。web 端 E2E 走 ego-browser，与本脚本无关。
#
# 前置：
#   1. 微信开发者工具已安装并已登录；`wechatide` 在 PATH（本机 ~/.local/bin/wechatide）
#   2. 首次调用 wechatide 会在工具内弹授权窗，需人工点同意（client 名 = CLIENT）
#
# 用法：pnpm e2e:order-pay-consent   （或 bash e2e/order-pay-deposit-consent.e2e.sh）
#
# 选择器纪律：Taro 4 weapp 运行时**不把 data-testid 渲染进 WXML**（渲染树只有
# id/class/data-sid），所以本脚本一律用 CSS-module 类名。哈希随样式变，故运行时
# 从 dist 产物里解析，不写死。另：wechatide 的 --wait-for-selector 是「执行**前**
# 等待」，用它等本步要操作的元素，不要当导航后的等待用。
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

ORDER_PAY='pages/order-pay'
NOTICE=$(cls "$ORDER_PAY" depositNotice)
ACK_ROW=$(cls "$ORDER_PAY" ackRow)
ACK_BOX_ON=$(cls "$ORDER_PAY" ackBoxChecked)
PAY_BTN=$(cls "$ORDER_PAY" primaryButton)

echo "### 1) 进入押金支付页（先试直达 mock 报名 enrollment-1，失败则走完整报名链）"
RAW automation_navigate --action reLaunch --url '/pages/order-pay/index?enrollmentId=enrollment-1' >/dev/null
sleep 2
if [ "$(COUNT "$NOTICE")" != "1" ]; then
  echo "  · 直达无押金块（mock 报名未就绪）→ 走 详情页 → 报名 → 支付页"
  DETAIL=$(cls 'pages/event-detail' primaryButton)
  LOGIN=$(cls 'pages/login' loginButton)
  AGREE=$(cls 'pages/login' dialogPrimary)
  SUBMIT=$(cls 'pages/register-form' primaryButton)

  RAW automation_navigate --action reLaunch --url '/pages/event-detail/index?id=event-deposit' >/dev/null
  wait_route '/pages/event-detail/index' || true
  TAP "$DETAIL"
  sleep 1
  if wait_route '/pages/login/index'; then
    TAP "$LOGIN"
    TAP "$AGREE"
    wait_route '/pages/register-form/index' || true
  fi
  TAP "$SUBMIT"
  wait_route '/pages/order-pay/index' || true
fi
ck "落在 order-pay" "$(ROUTE)" '/pages/order-pay/index'

echo "### 2) 资金动作前披露（口径 + 金额 = 订单快照）"
ck "押金金额行" "$(RES automation_element_action --action text --selector "$NOTICE")" '押金 ¥[0-9]+\.[0-9]{2}（到场退）'
ck "未到场不退明示" "$(RES automation_element_action --action text --selector "$NOTICE")" '未到场不退。'
ck "退还条件（勾选文案）" "$(RES automation_element_action --action text --selector "$NOTICE")" '押金以到场为退还条件'
ck "勾选行存在" "$(COUNT "$ACK_ROW")" '^1$'

echo "### 3) 未勾选不放行"
ck "按钮文案=请先勾选确认" "$(RES automation_element_action --action text --selector "$PAY_BTN")" '请先勾选确认'
ck "按钮 disabled=true" "$(RES automation_element_action --action property --name disabled --selector "$PAY_BTN")" '^true$'
ck "勾选盒未选中" "$(COUNT "$ACK_BOX_ON")" '^0$'

echo "### 4) 勾选后放行"
TAP "$ACK_ROW"
sleep 1
ck "勾选盒选中态" "$(COUNT "$ACK_BOX_ON")" '^1$'
ck "按钮文案=立即支付" "$(RES automation_element_action --action text --selector "$PAY_BTN")" '立即支付'
ck "按钮 disabled=false" "$(RES automation_element_action --action property --name disabled --selector "$PAY_BTN")" '^false$'

echo "### 5) 截图取证（给人看；脚本本身不做视觉判定）"
SHOT="${TMPDIR:-/tmp}/order-pay-deposit-consent.png"
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
