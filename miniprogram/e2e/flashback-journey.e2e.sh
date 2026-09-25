#!/usr/bin/env bash
# 「我的闪念间」旅程 E2E（小程序 / weapp 模拟器，本地回归用，**不进 CI**）
#
# 覆盖（闪念间主容器 = tabBar 页 pages/flashback-corridor；卡面单源 = components/MyCard）：
#   1. 未登录路人态：switchTab 长廊 → 公开金句首页（无名册内容）+ 找回入口 → 登录页（R32）
#   2. mock 登录链（手机号授权 passthrough）→ profile「我的」tab
#   3. tabBar 入口（自绘 AppTabBar 含「闪念间」项）+ 快门仪式层（U8：出现 → 点按 → 解散）
#      + 参与态长廊结构（卡 dock / 城市钉 / 时间帧 / 今天格 / 未来场次 / 愿望段 / 底部 CTA）
#   3.5–5. 我的卡开卡层（MyCard，类名在 common.wxss）：view 合着面 → 翻面 → 当年答案面
#      （题干/切句/雾面句/KTD4 本人原文完整）→ 点雾句解雾（R16）
#   6. 金句授权层默认关（R31：三档 + 选中「关闭」+ 圈选器不展开）
#   7. 今天写入面：write 入口直接翻面 → 写入 → 「写完寄出」一步到位（U5：层关 +
#      今天格点亮 + dock 回读）→ 金句授权引导层（nudge）弹出
#   7.5 nudge「选一句试试」→ 匿名档预选 → 圈选一句（R35）→ 匿名预览 → dock 回读
#      → 寄出+授权后点赞徽章（R36 正例）
#   8. 卡片页（pages/flashback-today）：四态 chip（默认合起来）+ 金句高亮（rvQuote）
#      + 分享面板（#771：朋友将看到的全文卡 → 允许生成分享链接 → 链接已开启 → 先不分享）
#   8.5 城市钉筛选（R34 重映射到长廊城市堆：点上海 → 堆 4→2 → 回全部恢复）
#   9. 愿望段：公开愿留言/附议/许愿/两步删除闭环 + 私愿折叠展开
#  批次二：
#   11. 首程旅程（token 面免登录 R1）：intro→quiz→reveal→翻面写→寄出浮层（R27/R29）
#   13. 长廊首程落地：welcome 金句引导（先不）+ 今天格已寄出 + 点堆进场次页
#   13.5 场次页：统计行 + 3 列网格（显影/雾卡）+ 找回 CTA + 回环三出口
#   14. 三级视角（R32）：路人围观 → 登录未匹配给出下一步 → 自动认领闭环（含快门）
#
# 为什么不在 CI：需要微信开发者工具 GUI（已登录）+ wechatide CLI，见
# miniprogram/AGENTS.md「E2E」一节。web 端 E2E 走 ego-browser，与本脚本无关。
#
# 已知边界（2026-09-21 重写时实测）：
#   - 行动板（四态行动卡）已随 refactor 移除（e0e0c0ed/41de6b0b/f14bc734），旧段
#     8/8.5/9/9.5 整段删除；城市钉筛选重映射到长廊城市堆。
#   - 金句授权档位行（licenseRow ×3 同类名）无法按文案点第 2 行：wechatide 选择器
#     实测不支持 :nth-child/:not/elementId/x-y 偏移（静默退化为首匹配）。匿名档切换
#     改走 nudge「选一句试试」（唯一锚点，且是产品既定的寄出后引导路径）。同理卡片页
#     四态 chip 不可点第 4 个「摘要卡」——摘要卡版式由 domain 单测钉住，e2e 只断言
#     默认「合起来」态。
#   - 今天写入面的「失焦自动保存」（saveOnBlur）自动化不可触发（input action 不聚焦，
#     点他处不派生 blur）——保存经「写完寄出」覆盖（sendToday 先 persistToday 再寄出）。
#   - loading 态一闪而过（mock 即时返回），不做断言。
#
# 前置：
#   1. 微信开发者工具已安装并已登录；`wechatide` 在 PATH（本机 ~/.local/bin/wechatide）
#   2. 首次调用 wechatide 会在工具内弹授权窗，需人工点同意（client 名 = CLIENT）
#   3. wechatide-skill 已装在 `.agents/skills/wechatide-skill`
#
# 用法：bash e2e/flashback-journey.e2e.sh
#
# 选择器纪律：Taro 4 weapp 运行时**不把 data-testid 渲染进 WXML**（渲染树只有
# id/class/data-sid，见 #579），所以本脚本一律用 CSS-module 类名。哈希随样式变，
# 故运行时从 dist 产物里解析，不写死：页面类读 pages/<page>/index.wxss（cls），
# MyCard/AppTabBar 等非页面组件的 CSS module 被 Taro 打进 common.wxss（clsCommon，
# 多哈希即跨组件同名 → 报错换锚，与 e2e/anchors.mjs 同纪律）。另：wechatide 的
# --wait-for-selector 是「执行**前**等待」，用它等本步要操作的元素，不要当导航后的
# 等待用。遮罩/模态中心被内容盖住、元素 tap 打不中时，用 trigger 派发 tap 事件
# （直发元素本身，不做命中测试）关层。
set -uo pipefail

CLIENT="${CGC_WECHATIDE_CLIENT:-DSH}"
MP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$MP_DIR/dist/weapp"
ART="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/artifacts"
mkdir -p "$ART"
PASS=0
FAIL=0

command -v wechatide >/dev/null || {
  echo "✗ 找不到 wechatide CLI。需安装微信开发者工具（含 wechatide），" >&2
  echo "  或在 PATH 上补软链；详见 miniprogram/AGENTS.md「E2E」一节。" >&2
  exit 2
}

# 缺依赖时别让它以「mock 构建失败」的面目出现（看不出真实原因）：新 worktree 跑过
# scripts/worktree/setup-worktree.sh 就会装好，没跑过的需自己装
[ -x "$MP_DIR/node_modules/.bin/taro" ] || {
  echo "✗ 缺小程序依赖（$MP_DIR/node_modules）。" >&2
  echo "  先执行：cd miniprogram && pnpm install --frozen-lockfile" >&2
  echo "  注：新 worktree 跑一次 scripts/worktree/setup-worktree.sh 即可装好。" >&2
  exit 2
}

RAW() { timeout 120 wechatide -c "$CLIENT" "$@" --project "$MP_DIR" 2>&1; }
# 取 toolCall 结果里的字符串值（text / property 类读取）
RES() { RAW "$@" | sed -n 's/.*"result": "\(.*\)"/\1/p' | tail -1; }
TAP() { RAW automation_element_action --selector "$1" --action tap --wait-for-selector "$1" >/dev/null; }
# 在唯一节点上派发自定义事件；type=tap 时用于「中心被遮罩内容盖住」的关层（直发元素，不做命中测试）
TRIGGER() { RAW automation_element_action --action trigger --type "$1" --detail "$2" --selector "$3" >/dev/null; }
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
shot() { RAW simulator_screenshot --path "$ART/$1" | grep -q '"success": true' && echo "  📷 $ART/$1"; }

# CSS-module 类名（哈希运行时解析）：cls <pages/xxx> <className>
cls() {
  local hit
  hit="$(grep -o "index-module__$2___[A-Za-z0-9_]*" "$DIST/$1/index.wxss" 2>/dev/null | head -1)"
  [ -n "$hit" ] || { echo "✗ 构建产物里找不到类名 $2（$1）——样式改动后请重跑 mock 构建" >&2; exit 2; }
  printf '.%s' "$hit"
}

# 组件类名（MyCard/AppTabBar/SharedFlashbackCard 等非页面组件，样式打进 common.wxss）：
# clsCommon <className> [模块名，默认 index]。多哈希 = 跨组件同名类（如 signName/icon），无法唯一定位，
# 直接报错换锚——与 e2e/anchors.mjs 的锚点纪律一致。
clsCommon() {
  local hits n
  # 第二参 = 样式模块名（默认 index）：组件样式不一定叫 index.module.css（如 endorse-sheet）
  hits="$(grep -o "${2:-index}-module__$1___[A-Za-z0-9_]*" "$DIST/common.wxss" 2>/dev/null | sort -u)"
  [ -n "$hits" ] || { echo "✗ common.wxss 里找不到类名 $1——样式改动后请重跑 mock 构建" >&2; exit 2; }
  n="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
  [ "$n" = "1" ] || { echo "✗ common.wxss 里类名 $1 有 $n 个哈希（跨组件同名），无法唯一定位——换锚点" >&2; exit 2; }
  printf '.%s' "$hits"
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

LOGIN='pages/login'
PROFILE='pages/profile'
COR='pages/flashback-corridor'
EVENT='pages/flashback-event'
TODAY='pages/flashback-today'

# 登录/我的页类名
LOGIN_BUTTON=$(cls "$LOGIN" loginButton)
DIALOG_PRIMARY=$(cls "$LOGIN" dialogPrimary)
LOGOUT=$(cls "$PROFILE" logout)

# 长廊页类名
CTA=$(cls "$COR" cta)
GUEST_RECOVER=$(cls "$COR" recoverButton)
GUEST_QUOTE=$(cls "$COR" quoteOpen)
GUEST_VOICES=$(cls "$COR" voicesPortal)
GUEST_WISHES=$(cls "$COR" wishesPortal)
CAPWHEN=$(cls "$COR" capWhen)
CAPLABEL=$(cls "$COR" capLabel)
PINPOL=$(cls "$COR" pinPolaroid)
PINCITY=$(cls "$COR" pinCity)
PINCOUNT=$(cls "$COR" pinCount)
CAPRETURNED=$(cls "$COR" capReturned)
CARDDOCK=$(cls "$COR" cardDock)
MINICARD=$(cls "$COR" miniCard)
MINICARD_NAME=$(cls "$COR" miniCardName)
MINICARD_FACTS=$(cls "$COR" miniCardFacts)
MINICARD_HINT=$(cls "$COR" miniCardHint)
DOCK_WRITE=$(cls "$COR" dockWritePrimary)
DOCK_SEND=$(cls "$COR" dockSend)
DOCK_LICENSE=$(cls "$COR" dockLicense)
CITY_PINS=$(cls "$COR" cityPins)
CITY_PIN=$(cls "$COR" cityPin)
CITY_PIN_ALL=$(cls "$COR" cityPinAll)
CITY_PIN_ACTIVE=$(cls "$COR" cityPinActive)
TODAY_TITLE=$(cls "$COR" todayTitle)
TODAY_VACANT_TEXT=$(cls "$COR" todayVacantText)
TODAY_LIT=$(cls "$COR" todayLit)
TODAY_LIT_NAME=$(cls "$COR" todayLitName)
TODAY_LIT_CAP=$(cls "$COR" todayLitCap)
CAP_FUTURE=$(cls "$COR" capFuture)
CAP_FUTURE_DIM=$(cls "$COR" capFutureDim)
FUTURE_TITLE=$(cls "$COR" futureTitleDark)
EVENT_CARD=$(cls "$COR" eventCard)
EVENT_CARD_LIT=$(cls "$COR" eventCardLit)
EVENT_CARD_MUTED=$(cls "$COR" eventCardMuted)
EVENT_TITLE=$(cls "$COR" eventTitle)
EVENT_CTA=$(cls "$COR" eventCta)
EVENT_BADGE=$(cls "$COR" eventBadge)
WISH_ADD=$(cls "$COR" wishAddBtn)
WISH_CARD=$(cls "$COR" wishCard)
WISH_CONTENT=$(cls "$COR" wishContent)
WISH_ENDORSE=$(cls "$COR" wishEndorse)
WISH_ENDORSED=$(cls "$COR" wishEndorsed)
WISH_DELETE=$(cls "$COR" wishDelete)
WISH_MODAL=$(cls "$COR" wishModal)
WISH_MODAL_MASK=$(cls "$COR" wishModalMask)
WISH_MODAL_CONTENT=$(cls "$COR" wishModalContent)
WISH_COMMENTS_TITLE=$(cls "$COR" wishCommentsTitle)
WISH_COMMENT_ROW=$(cls "$COR" wishCommentRow)
WISH_COMMENT_TEXT=$(cls "$COR" wishCommentText)
WISH_COMMENT_INPUT=$(cls "$COR" wishCommentInput)
WISH_INPUT=$(cls "$COR" wishInput)
WISH_SHEET_MASK=$(clsCommon endorseMask endorse-sheet)
WISH_SHEET_SUBMIT=$(clsCommon endorseSubmit endorse-sheet)
WISH_RECEIPT_DONE=$(clsCommon receiptDone endorse-sheet)
ENDORSE_CHIP=$(clsCommon endorseChip endorse-sheet)
ENDORSE_NOTIFY=$(clsCommon endorseNotify endorse-sheet)
PRIVATE_FOLD=$(cls "$COR" privateFold)
PRIVATE_FOLD_LABEL=$(cls "$COR" privateFoldLabel)
PRIVATE_FOLD_ARROW=$(cls "$COR" privateFoldArrow)
WISH_CARD_PRIVATE=$(cls "$COR" wishCardPrivate)
LAYER_MASK=$(cls "$COR" layerMask)
LAYER_CLOSE=$(cls "$COR" layerClose)
WALL_OFF=$(cls "$COR" wallOff)
WALL_ON=$(cls "$COR" wallOn)
MASK_LIKE=$(cls "$COR" maskLike)
SHUTTER_MASK=$(cls "$COR" shutterMask)
SHUTTER_BTN=$(cls "$COR" shutterBtn)
SHUTTER_EYEBROW=$(cls "$COR" shutterEyebrow)
SHUTTER_LEAD=$(cls "$COR" shutterLead)
SHUTTER_HINT=$(cls "$COR" shutterHint)
NUDGE_MASK=$(cls "$COR" nudgeMask)
NUDGE_LEAD=$(cls "$COR" nudgeLead)
NUDGE_SUB=$(cls "$COR" nudgeSub)
NUDGE_PRIMARY=$(cls "$COR" nudgePrimary)
NUDGE_SKIP=$(cls "$COR" nudgeSkip)
SHEET_MASK=$(cls "$COR" wishSheetMask)
SHEET_TITLE=$(cls "$COR" wishSheetTitle)
COURAGE=$(cls "$COR" courageBadgeText)
LICENSE_ROW=$(cls "$COR" licenseRow)
LICENSE_ROW_ACTIVE=$(cls "$COR" licenseRowActive)
LICENSE_LABEL=$(cls "$COR" licenseLabel)
LICENSE_FOOT=$(cls "$COR" licenseFoot)
QUOTE_PICKER=$(cls "$COR" quotePickerSheet)
QUOTE_PICKHINT=$(cls "$COR" quotePickHint)
QUOTE_CANDIDATE=$(cls "$COR" quoteCandidate)
QUOTE_CANDIDATE_ACTIVE=$(cls "$COR" quoteCandidateActive)
QUOTE_CANDIDATE_FOGGED=$(cls "$COR" quoteCandidateFogged)
QUOTE_PREVIEW=$(cls "$COR" quotePreview)
QUOTE_PREVIEW_Q=$(cls "$COR" quotePreviewQ)
QUOTE_PREVIEW_NAME=$(cls "$COR" quotePreviewName)
QUOTE_PREVIEW_DIM=$(cls "$COR" quotePreviewDim)

# MyCard / AppTabBar / SharedFlashbackCard 组件类名（common.wxss）
CARD_FLIP=$(clsCommon cardFlip)
CARD_FLIPPED=$(clsCommon cardFlipFlipped)
SENTENCE=$(clsCommon sentence)
SENTENCE_FOGGED=$(clsCommon sentenceFogged)
FOG_HINT=$(clsCommon fogHint)
PAPER_Q=$(clsCommon paperQ)
WRITE_INPUT=$(clsCommon writeInput)
WRITE_LABEL=$(clsCommon writeLabel)
PAPER_TODAY_TITLE=$(clsCommon paperTodayTitle)
SEND_BTN=$(clsCommon sendBtn)
SEND_NOTE=$(clsCommon sendNote)
BACK_LINK=$(clsCommon backLink)
RV_SENTENCE=$(clsCommon rvSentence)
RV_FOG=$(clsCommon rvFog)
RV_QUOTE=$(clsCommon rvQuote)
SHARE_OPTIN=$(clsCommon shareOptIn)
SHARE_OPTIN_LABEL=$(clsCommon shareOptInLabel)
TAB_BAR=$(clsCommon bar)
TAB_ITEM=$(clsCommon item)
TAB_SELECTED=$(clsCommon selected)
SC_KICKER=$(clsCommon kicker)
SC_STAMP=$(clsCommon stamp)
SC_PHOTO_TITLE=$(clsCommon photoTitle)

# 卡片页类名
MODE_CHIP=$(cls "$TODAY" modeChip)
MODE_CHIP_ACTIVE=$(cls "$TODAY" modeChipActive)
TODAY_TIP=$(cls "$TODAY" tip)
ACTION_SECONDARY=$(cls "$TODAY" actionSecondary)
SHARE_MASK=$(cls "$TODAY" shareMask)
SHARE_TITLE=$(cls "$TODAY" shareTitle)
SHARE_NOTICE_LINE=$(cls "$TODAY" shareNoticeLine)
SHARE_CONSENT=$(cls "$TODAY" shareConsent)
SHARE_PRIMARY=$(cls "$TODAY" sharePrimary)
SHARE_STATUS_ON=$(cls "$TODAY" shareStatusOn)
SHARE_STATUS_HINT=$(cls "$TODAY" shareStatusHint)
SHARE_CANCEL=$(cls "$TODAY" shareCancel)

echo "### 0) 清态：退出残留登录 + 清闪念间相关 storage（mock 持久档/token/intent/nudge/视角开关；不清则跨跑残留）"
RAW automation_navigate --action reLaunch --url '/pages/profile/index' >/dev/null
sleep 2
# 清 storage 放 reLaunch 后（runtime 已就绪）；刚开窗口时 evaluate 可能还没就绪，重试一次
cleared=0
for _ in 1 2; do
  if RAW automation_evaluate --fn-source 'function(){ wx.removeStorageSync("cgc.e2e.flashback_mock_state"); wx.removeStorageSync("cgc.flashback_token"); wx.removeStorageSync("cgc.flashback_entry_intent"); wx.removeStorageSync("cgc.flashback_license_nudge_done"); wx.removeStorageSync("cgc.workspace_tab_visible"); wx.removeStorageSync("cgc.e2e.flashback_unclaimed"); wx.removeStorageSync("cgc.e2e.flashback_claim_miss"); wx.removeStorageSync("cgc.e2e.workspace_access_denied") }' \
    | grep -q '"success": true'; then cleared=1; break; fi
  sleep 1.5
done
[ "$cleared" = 1 ] || { echo "✗ 清 flashback storage 失败（automation_evaluate）" >&2; exit 2; }
if [ "$(COUNT "$LOGOUT")" != "0" ]; then
  TAP "$LOGOUT"
  sleep 1
fi
ck "清态后未登录（无退出按钮）" "$(COUNT "$LOGOUT")" '^0$'

echo "### 1) 未登录路人态（R32）：switchTab 长廊 → 公开金句首页（无名册内容）+ 找回入口 → 登录页"
RAW automation_navigate --action switchTab --url '/pages/flashback-corridor/index' >/dev/null
sleep 3
ck "落在长廊 tab" "$(ROUTE)" '/pages/flashback-corridor/index'
ck "访客找回入口" "$(RES automation_element_action --action text --selector "$GUEST_RECOVER")" '^找回你的那一张 →$'
ck "访客显示一张公开金句卡" "$(COUNT "$GUEST_QUOTE")" '^1$'
ck "金句墙入口可见" "$(COUNT "$GUEST_VOICES")" '^1$'
ck "许愿树入口可见" "$(COUNT "$GUEST_WISHES")" '^1$'
ck "访客首页不渲染历史统计堆" "$(COUNT "$PINPOL")" '^0$'
ck "路人无卡 dock（member 才渲染）" "$(COUNT "$CARDDOCK")" '^0$'
ck "访客首页无城市钉/愿望列表/场次卡" "$(COUNT "$CITY_PIN")/$(COUNT "$WISH_CARD")/$(COUNT "$EVENT_CARD")" '^0/0/0$'
ck "访客不渲染个人今天空位" "$(COUNT "$TODAY_VACANT_TEXT")" '^0$'
ck "路人无快门仪式（member 专属）" "$(COUNT "$SHUTTER_MASK")" '^0$'
shot 01-corridor-viewer.png
# 直发元素 tap（不做命中测试）：一次整跑中 TAP 命中过上方金句卡（落金句墙），
# 单独复测 10/10 未复现；本断言验的是按钮接线，不依赖命中测试时的布局
TRIGGER tap '{}' "$GUEST_RECOVER"
wait_route '/pages/login/index' || true
ck "CTA 落登录页（带 returnUrl 回跳长廊）" "$(ROUTE)" 'pages/login/index\?returnUrl='

echo "### 2) mock 登录链（手机号授权 passthrough，不碰真实凭据）"
RAW automation_evaluate --fn-source 'function(){ wx.setStorageSync("cgc.e2e.workspace_access_denied", "1") }' >/dev/null
RAW automation_navigate --action reLaunch --url '/pages/login/index' >/dev/null
sleep 2
TAP "$LOGIN_BUTTON"
sleep 1
TAP "$DIALOG_PRIMARY"
wait_route '/pages/profile/index' || true
ck "登录成功落「我的」tab" "$(ROUTE)" '/pages/profile/index'
shot 02-after-login-profile.png

echo "### 3) tabBar 入口 + 快门仪式（U8）+ 参与态长廊结构"
ck "无工作台权限的 tabBar 三项（发现/闪念间/我的）" "$(COUNT "$TAB_ITEM")" '^3$'
ck "tabBar 含「闪念间」项" "$(RES automation_element_action --action text --selector "$TAB_BAR")" '闪念间'
ck "当前选中=我的" "$(RES automation_element_action --action text --selector "$TAB_SELECTED")" '我的$'
RAW automation_navigate --action switchTab --url '/pages/flashback-corridor/index' >/dev/null
sleep 3.5
ck "switchTab 达长廊" "$(ROUTE)" '/pages/flashback-corridor/index'
ck "快门仪式层出现（member 进门）" "$(COUNT "$SHUTTER_MASK")" '^1$'
ck "仪式 eyebrow" "$(RES automation_element_action --action text --selector "$SHUTTER_EYEBROW")" '^IN A FLASH · 闪念间$'
ck "仪式引子（JSON 换行转义形态）" "$(RES automation_element_action --action text --selector "$SHUTTER_LEAD")" '多年前，\\n你写过一些答案。'
ck "橙色快门钮在" "$(COUNT "$SHUTTER_BTN")" '^1$'
ck "快门提示" "$(RES automation_element_action --action text --selector "$SHUTTER_HINT")" '^按下快门，回到那天$'
shot 03-corridor-shutter.png
TAP "$SHUTTER_BTN"
sleep 1
ck "点按快门后仪式层解散" "$(COUNT "$SHUTTER_MASK")" '^0$'
ck "卡 dock 在（mini 卡 + 三动作）" "$(COUNT "$CARDDOCK")" '^1$'
ck "mini 卡全名" "$(RES automation_element_action --action text --selector "$MINICARD_NAME")" '^王小明$'
ck "mini 卡年份 · 城市" "$(RES automation_element_action --action text --selector "$MINICARD_FACTS")" '^2014 · 北京$'
ck "mini 卡提示" "$(RES automation_element_action --action text --selector "$MINICARD_HINT")" '^点卡片翻开$'
ck "dock 写入口（今天未写无 ✓）" "$(RES automation_element_action --action text --selector "$DOCK_WRITE")" '^✎ 写今天的你$'
ck "dock 寄出（未寄出态）" "$(RES automation_element_action --action text --selector "$DOCK_SEND")" '^写完寄出 →$'
ck "dock 授权（默认关无后缀）" "$(RES automation_element_action --action text --selector "$DOCK_LICENSE")" '^← 金句授权$'
ck "城市钉 3（名册城市：上海/北京/广州）" "$(COUNT "$CITY_PIN")" '^3$'
ck "初始选中=全部（全部钉带选中态）" "$(RES automation_element_action --action text --selector "$CITY_PIN_ALL$CITY_PIN_ACTIVE")" '^全部$'
ck "时间帧 2（升序）" "$(COUNT "$CAPWHEN")" '^2$'
ck "第一帧=2012.02.26" "$(RES automation_element_action --action text --selector "$CAPWHEN")" '^2012\.02\.26'
ck "首帧叙事标签=一切的开始" "$(RES automation_element_action --action text --selector "$CAPLABEL")" '一切的开始$'
ck "城市堆 4（上海场 1 堆 + 北京场 北京/上海/广州 3 堆）" "$(COUNT "$PINPOL")" '^4$'
ck "首堆=上海 · 3 位" "$(RES automation_element_action --action text --selector "$PINCITY")/$(RES automation_element_action --action text --selector "$PINCOUNT")" '^上海/3 位$'
ck "已回来标记 3 堆（上海场 2 位 + 北京场两堆各 1 位）" "$(COUNT "$CAPRETURNED")" '^3$'
ck "今天格标头（动态日期）" "$(RES automation_element_action --action text --selector "$TODAY_TITLE")" '^⚡ 今天 [0-9]+\.[0-9]+\.[0-9]+ · 此刻 · 一闪念间$'
ck "今天格=你的位置（member 未寄出）" "$(RES automation_element_action --action text --selector "$TODAY_VACANT_TEXT")" '^你的位置$'
ck "未来场次帧头（日期 · 倡议名）" "$(RES automation_element_action --action text --selector "$CAP_FUTURE")" '^[0-9]+\.[0-9]+ · Hacker Start 1024$'
ck "未来帧未显影标记" "$(RES automation_element_action --action text --selector "$CAP_FUTURE_DIM")" '^未显影$'
ck "未来段标题" "$(RES automation_element_action --action text --selector "$FUTURE_TITLE")" '^未来 · 一起做什么$'
ck "未来场次卡 3" "$(COUNT "$EVENT_CARD")" '^3$'
ck "亮金可报名 1 / 灰卡 2" "$(COUNT "$EVENT_CARD_LIT")/$(COUNT "$EVENT_CARD_MUTED")" '^1/2$'
ck "首张场卡=Agent 入门工作坊" "$(RES automation_element_action --action text --selector "$EVENT_TITLE")" '^Agent 入门工作坊$'
RAW automation_viewport_action --action pageScrollTo --scroll-top 850 >/dev/null
ck "可报名卡 CTA=报名 →" "$(RES automation_element_action --action text --selector "$EVENT_CTA")" '^报名 →$'
ck "满员卡徽章=名额已满" "$(RES automation_element_action --action text --selector "$EVENT_BADGE")" '^名额已满$'
RAW automation_viewport_action --action pageScrollTo --scroll-top 0 >/dev/null
ck "公开愿望卡 2" "$(COUNT "$WISH_CARD")" '^2$'
ck "首愿内容" "$(RES automation_element_action --action text --selector "$WISH_CONTENT")" '^一起出一本书:《她们的第一行代码》$'
ck "首愿附议行（未附议态）" "$(RES automation_element_action --action text --selector "$WISH_ENDORSE")" '^👍 5$'
ck "次愿已附议态" "$(RES automation_element_action --action text --selector "$WISH_ENDORSED")" '^👍 2 · 已附议$'
ck "许愿入口" "$(RES automation_element_action --action text --selector "$WISH_ADD")" '^写下我的愿望 ＋$'
ck "私愿折叠行" "$(RES automation_element_action --action text --selector "$PRIVATE_FOLD_LABEL")" '^🔒 私人许愿\(1 条\)$'
ck "私愿折叠箭头" "$(RES automation_element_action --action text --selector "$PRIVATE_FOLD_ARROW")" '^展开 ▼$'
ck "底部 CTA=把这一刻做成卡片" "$(RES automation_element_action --action text --selector "$CTA")" '^把这一刻做成卡片 →$'
shot 03.5-corridor-member.png

echo "### 3.5) 我的卡开卡层两态（MyCard 单源）：view 停合着面 → 点按翻面看写入面 → 合回"
TAP "$MINICARD"
sleep 2
ck "开卡层出现（暗场）" "$(COUNT "$LAYER_MASK")" '^1$'
ck "3D 翻面容器在" "$(COUNT "$CARD_FLIP")" '^1$'
ck "view 入口停在合着面（未翻面）" "$(COUNT "$CARD_FLIPPED")" '^0$'
ck "层 chrome=未寄出口径" "$(RES automation_element_action --action text --selector "$WALL_OFF")" '^点击照片翻面写字 · 再点寄出$'
ck "未寄出：无点赞徽章（R36）" "$(COUNT "$MASK_LIKE")" '^0$'
TAP "$FOG_HINT"
sleep 1.2
ck "点当年面翻到今天写入面" "$(COUNT "$CARD_FLIPPED")" '^1$'
ck "写入面 4 行输入（现在/想学/帮助/想说）" "$(COUNT "$WRITE_INPUT")" '^4$'
ck "首行标签=现在在做什么" "$(RES automation_element_action --action text --selector "$WRITE_LABEL")" '^现在在做什么$'
ck "写入面标题（动态日期）" "$(RES automation_element_action --action text --selector "$PAPER_TODAY_TITLE")" '^今天的你 · [0-9]+\.[0-9]+\.[0-9]+$'
ck "寄出钮=写完寄出" "$(RES automation_element_action --action text --selector "$SEND_BTN")" '^写完寄出 →$'
ck "寄出公开性提示" "$(RES automation_element_action --action text --selector "$SEND_NOTE")" '^寄出即公开 · 包括当年的答案 · 随时可调$'
ck "回当年面链接" "$(RES automation_element_action --action text --selector "$BACK_LINK")" '^← 回到当年答案$'
shot 035-card-write-face.png
TAP "$BACK_LINK"
sleep 1
ck "合回当年答案面" "$(COUNT "$CARD_FLIPPED")" '^0$'

echo "### 4) 当年答案面（题干 + 句子级雾面 + KTD4 本人原文完整）"
ck "题干 2（self_intro + funny_thing）" "$(COUNT "$PAPER_Q")" '^2$'
ck "首题干=请简单的介绍一下自己" "$(RES automation_element_action --action text --selector "$PAPER_Q")" '^请简单的介绍一下自己$'
ck "切句=4 句（自我介绍 3 句 + 有意思的事 1 句）" "$(COUNT "$SENTENCE")" '^4$'
ck "雾面句=1 句（mock fogSpans [0,7) 只罩首句）" "$(COUNT "$SENTENCE_FOGGED")" '^1$'
ck "本人视图首句永远完整（KTD4）" "$(RES automation_element_action --action text --selector "$SENTENCE")" '^我在盛大做测试。'
ck "雾化操作提示" "$(RES automation_element_action --action text --selector "$FOG_HINT")" '^点句子可切换雾面 · 雾面句对外不可见$'
shot 04-card-front-fog.png

echo "### 5) 雾化编辑：点按雾面句 → 解雾（R16 句子级开关）"
TAP "$SENTENCE_FOGGED"
sleep 1.5
ck "点按后雾面清空" "$(COUNT "$SENTENCE_FOGGED")" '^0$'
shot 05-card-fog-cleared.png
TAP "$LAYER_CLOSE"
sleep 1
ck "合卡层关闭" "$(COUNT "$LAYER_MASK")" '^0$'

echo "### 6) 金句授权层·默认关（R31）：dock 入口 → 三档 + 选中「关闭」+ 圈选器不展开"
TAP "$DOCK_LICENSE"
sleep 1.5
ck "授权层弹出" "$(COUNT "$SHEET_MASK")" '^1$'
ck "层标题=金句授权" "$(RES automation_element_action --action text --selector "$SHEET_TITLE")" '^金句授权$'
ck "勇气语徽章" "$(RES automation_element_action --action text --selector "$COURAGE")" '^你说的话会成为别人的勇气！$'
ck "三档选项" "$(COUNT "$LICENSE_ROW")" '^3$'
ck "默认选中恰好一档=关闭" "$(RES automation_element_action --action text --selector "$LICENSE_ROW_ACTIVE $LICENSE_LABEL")" '^关闭$'
ck "关档下圈选器不展开" "$(COUNT "$QUOTE_PICKER")" '^0$'
ck "底部口径=默认全部关闭" "$(RES automation_element_action --action text --selector "$LICENSE_FOOT")" '^你的授权随时可调，默认全部关闭$'
TRIGGER tap '{}' "$SHEET_MASK"
sleep 1
ck "授权层关闭（遮罩 trigger 关层）" "$(COUNT "$SHEET_MASK")" '^0$'

echo "### 7) 今天写入面：write 入口 → 写入 → 写完寄出（U5 三拍收尾）→ 金句引导层弹出"
TAP "$DOCK_WRITE"
sleep 1.5
ck "write 入口直接落在写入面（autoOpen 翻面）" "$(COUNT "$CARD_FLIPPED")" '^1$'
RAW automation_element_action --action input --selector "$WRITE_INPUT" --value 'E2E 闪念间回访' >/dev/null
sleep 0.5
ck "首行输入回读" "$(RES automation_element_action --action value --selector "$WRITE_INPUT")" '^E2E 闪念间回访$'
TAP "$SEND_BTN"
sleep 3
ck "寄出后开卡层关闭（落定三拍之一）" "$(COUNT "$LAYER_MASK")" '^0$'
ck "金句授权引导层弹出（寄出落定轻推）" "$(COUNT "$NUDGE_MASK")" '^1$'
ck "引导勇气语" "$(RES automation_element_action --action text --selector "$NUDGE_LEAD")" '^你说的话，会成为别人的勇气。$'
ck "引导副文案" "$(RES automation_element_action --action text --selector "$NUDGE_SUB")" '^从当年的答案里选一句，匿名或实名地传下去。$'
ck "引导主钮=选一句试试" "$(RES automation_element_action --action text --selector "$NUDGE_PRIMARY")" '^选一句试试 →$'
ck "引导次出口=先不" "$(RES automation_element_action --action text --selector "$NUDGE_SKIP")" '^先不$'
ck "dock 寄出回读=已寄出 ✓" "$(RES automation_element_action --action text --selector "$DOCK_SEND")" '^已寄出 ✓$'
ck "dock 写入口补完成态勾" "$(RES automation_element_action --action text --selector "$DOCK_WRITE")" '^✎ 写今天的你 ✓$'
ck "今天格点亮（瘦长黑相纸）" "$(COUNT "$TODAY_LIT")" '^1$'
ck "今天格照片=本人名" "$(RES automation_element_action --action text --selector "$TODAY_LIT_NAME")" '^王小明$'
shot 07-corridor-sent-nudge.png

echo "### 7.5) nudge「选一句试试」→ 匿名档预选 + 圈选一句（R35）→ 匿名预览 → 回读 + R36 点赞徽章"
TAP "$NUDGE_PRIMARY"
sleep 2
ck "引导转授权层" "$(COUNT "$SHEET_MASK")" '^1$'
ck "引导层已关" "$(COUNT "$NUDGE_MASK")" '^0$'
ck "预选档=匿名金句（nudge 路径）" "$(RES automation_element_action --action text --selector "$LICENSE_ROW_ACTIVE $LICENSE_LABEL")" '^匿名金句$'
ck "首行档仍=关闭（三档都在）" "$(RES automation_element_action --action text --selector "$LICENSE_ROW $LICENSE_LABEL")" '^关闭$'
ck "圈选器展开，已选 0 句" "$(RES automation_element_action --action text --selector "$QUOTE_PICKHINT")" '已选 0 句$'
ck "候选句=5（当年 4 句已解雾 + 今天 1 句）" "$(COUNT "$QUOTE_CANDIDATE")" '^5$'
ck "无雾句候选（段 5 已解雾）" "$(COUNT "$QUOTE_CANDIDATE_FOGGED")" '^0$'
TAP "$QUOTE_CANDIDATE"
sleep 2
ck "圈选后高亮恰一句" "$(COUNT "$QUOTE_CANDIDATE_ACTIVE")" '^1$'
ck "已选计数=1" "$(RES automation_element_action --action text --selector "$QUOTE_PICKHINT")" '已选 1 句$'
ck "匿名预览金句=首句原文" "$(RES automation_element_action --action text --selector "$QUOTE_PREVIEW_Q")" '^「我在盛大做测试。」$'
ck "匿名预览署名=王** · 2014 · 北京" "$(RES automation_element_action --action text --selector "$QUOTE_PREVIEW_NAME")" '^王\*\* · 2014 · 北京$'
ck "匿名预览=不可点" "$(RES automation_element_action --action text --selector "$QUOTE_PREVIEW_DIM")" '^匿名 · 不可点$'
ck "dock 授权回读=匿名 ✓（capsule.me.quoteLevel）" "$(RES automation_element_action --action text --selector "$DOCK_LICENSE")" '^← 金句授权 · 匿名 ✓$'
shot 075-license-anonymous.png
TRIGGER tap '{}' "$SHEET_MASK"
sleep 1
ck "授权层关闭" "$(COUNT "$SHEET_MASK")" '^0$'
TAP "$MINICARD"
sleep 2
ck "寄出后层 chrome=已寄出到校友墙" "$(RES automation_element_action --action text --selector "$WALL_ON")" '^已寄出到校友墙$'
ck "点赞徽章出现（R36 正例：寄出+授权+有赞）" "$(RES automation_element_action --action text --selector "$MASK_LIKE")" '^❤ 3$'
TAP "$LAYER_CLOSE"
sleep 1

echo "### 8) 卡片页（长廊 CTA → flashback-today）：四态 chip + 金句高亮 + 分享面板（#771）"
TAP "$CTA"
wait_route '/pages/flashback-today/index' || true
ck "落卡片页" "$(ROUTE)" '/pages/flashback-today/index'
ck "四态 chip 4" "$(COUNT "$MODE_CHIP")" '^4$'
ck "默认选中=合起来" "$(RES automation_element_action --action text --selector "$MODE_CHIP_ACTIVE")" '^合起来$'
ck "两段句数=5（今天 1 + 当年 4）" "$(COUNT "$RV_SENTENCE")" '^5$'
ck "无雾句（段 5 解雾后）" "$(COUNT "$RV_FOG")" '^0$'
ck "金句浅金高亮恰一句（rvQuote）" "$(COUNT "$RV_QUOTE")" '^1$'
ck "页底提示=点句切雾" "$(RES automation_element_action --action text --selector "$TODAY_TIP")" '^点句子可切换雾面 · 雾面句对外不可见$'
ck "金句 opt-in 行（R37 已授权=勾上态）" "$(COUNT "$SHARE_OPTIN")" '^1$'
ck "opt-in 文案=已允许 · 点按关闭" "$(RES automation_element_action --action text --selector "$SHARE_OPTIN_LABEL")" '^已允许金句放进金句墙 · 点按关闭$'
TAP "$ACTION_SECONDARY"
sleep 1.5
ck "分享面板弹出" "$(COUNT "$SHARE_MASK")" '^1$'
ck "面板标题=朋友将看到的全文卡" "$(RES automation_element_action --action text --selector "$SHARE_TITLE")" '^朋友将看到的全文卡$'
ck "四条边界提示" "$(COUNT "$SHARE_NOTICE_LINE")" '^4$'
ck "开启前知情文案" "$(RES automation_element_action --action text --selector "$SHARE_CONSENT")" '^开启后，任何拿到链接的人都能看到上面这张卡。随时可以关。$'
ck "主钮=允许生成分享链接" "$(RES automation_element_action --action text --selector "$SHARE_PRIMARY")" '^允许生成分享链接$'
ck "预览卡 kicker（与访客读面同组件）" "$(RES automation_element_action --action text --selector "$SC_KICKER")" '^IN A FLASH · 闪念间$'
ck "预览卡场景标=城市 · 活动日" "$(RES automation_element_action --action text --selector "$SC_STAMP")" '^北京 · 2014\.01\.11$'
ck "预览卡两段（当年的你 + 今天的你）" "$(COUNT "$SC_PHOTO_TITLE")" '^2$'
TAP "$SHARE_PRIMARY"
sleep 2
ck "开启后=链接已开启" "$(RES automation_element_action --action text --selector "$SHARE_STATUS_ON")" '^链接已开启$'
ck "开启后提示" "$(RES automation_element_action --action text --selector "$SHARE_STATUS_HINT")" '^朋友点开就能看到上面这张卡$'
shot 08-today-share-enabled.png
TAP "$SHARE_CANCEL"
sleep 1
ck "先不分享后面板关闭" "$(COUNT "$SHARE_MASK")" '^0$'
RAW automation_navigate --action navigateBack >/dev/null
sleep 2.5
ck "返回长廊" "$(ROUTE)" '/pages/flashback-corridor/index'
ck "授权档回读仍=匿名（capsule.me.quoteLevel，P3）" "$(RES automation_element_action --action text --selector "$DOCK_LICENSE")" '^← 金句授权 · 匿名 ✓$'

echo "### 8.5) 城市钉筛选（R34 重映射到长廊城市堆）：点上海 → 堆 4→2；回全部恢复"
ck "城市钉 3 + 全部钉选中" "$(COUNT "$CITY_PIN")/$(RES automation_element_action --action text --selector "$CITY_PIN_ALL$CITY_PIN_ACTIVE")" '^3/全部$'
ck "筛选前堆 4" "$(COUNT "$PINPOL")" '^4$'
TAP "$CITY_PIN"
sleep 2.5
ck "筛上海后堆只剩 2（两场的上海堆）" "$(COUNT "$PINPOL")" '^2$'
ck "选中钉切到上海" "$(RES automation_element_action --action text --selector "$CITY_PIN_ACTIVE")" '^上海$'
ck "钉条不随过滤收缩（仍 3 城钉）" "$(COUNT "$CITY_PIN")" '^3$'
shot 08.5-corridor-city-filtered.png
TRIGGER tap '{}' "$CITY_PIN_ALL"
sleep 2.5
ck "回全部恢复 4 堆" "$(COUNT "$PINPOL")" '^4$'
ck "选中钉回全部" "$(RES automation_element_action --action text --selector "$CITY_PIN_ALL$CITY_PIN_ACTIVE")" '^全部$'

echo "### 9) 愿望段：留言、附议、许愿、两步删除 + 私愿折叠"
# 长廊愿望段在首屏下方；wechatide 的可视坐标 tap 对离屏卡不稳定，
# 直接向唯一目标类的首元素派发 tap，仍走页面 onClick 与后续真实写面。
TRIGGER tap '{}' "$WISH_CARD"
sleep 1.5
ck "愿望模态弹出" "$(COUNT "$WISH_MODAL")" '^1$'
ck "模态全文" "$(RES automation_element_action --action text --selector "$WISH_MODAL_CONTENT")" '^一起出一本书:《她们的第一行代码》$'
ck "留言区标题=留言(1)" "$(RES automation_element_action --action text --selector "$WISH_COMMENTS_TITLE")" '^留言\(1\)$'
ck "留言 1 条" "$(COUNT "$WISH_COMMENT_ROW")" '^1$'
ck "留言内容" "$(RES automation_element_action --action text --selector "$WISH_COMMENT_TEXT")" '^算我一个$'
ck "模态附议行=🙌 我能出力 · 5" "$(RES automation_element_action --action text --selector "$WISH_MODAL $WISH_ENDORSE")" '^🙌 我能出力 · 5$'
RAW automation_element_action --action input --selector "$WISH_INPUT" --value 'E2E 留言' >/dev/null
TAP "$WISH_COMMENT_INPUT button"
sleep 1.5
ck "留言后标题=留言(2)" "$(RES automation_element_action --action text --selector "$WISH_COMMENTS_TITLE")" '^留言\(2\)$'
ck "留言后两条可读" "$(COUNT "$WISH_COMMENT_ROW")" '^2$'
shot 09-wish-modal.png
TRIGGER tap '{}' "$WISH_MODAL_MASK"
sleep 1
ck "模态关闭" "$(COUNT "$WISH_MODAL")" '^0$'
TRIGGER tap '{}' "$WISH_CARD"
sleep 0.8
TAP "$WISH_MODAL $WISH_ENDORSE"
sleep 0.8
ck "附议表单打开" "$(COUNT "$WISH_SHEET_MASK")" '^1$'
TAP "$ENDORSE_CHIP"
TAP "$ENDORSE_NOTIFY"
TAP "$WISH_SHEET_SUBMIT"
sleep 1.5
TAP "$WISH_RECEIPT_DONE"
sleep 1.5
ck "附议后表单关闭" "$(COUNT "$WISH_SHEET_MASK")" '^0$'
ck "首愿附议数 +1 且本人已附议" "$(RES automation_element_action --action text --selector "$WISH_CARD $WISH_ENDORSED")" '^👍 6 · 已附议$'

TRIGGER tap '{}' "$WISH_ADD"
sleep 0.8
WRITE='pages/flashback-wish-write'
ck "许愿页打开" "$(RES automation_element_action --action text --selector "$(cls "$WRITE" title)")" '^写下我的愿望$'
RAW automation_element_action --action input --selector "$(cls "$WRITE" contentInput)" --value 'E2E 年度愿望' >/dev/null
RAW automation_element_action --action input --selector "$(cls "$WRITE" cityInput)" --value '北京' >/dev/null
TAP "$(cls "$WRITE" submit)"
sleep 1.5
ck "许愿后进入我的愿望" "$(RES automation_element_action --action text --selector "$(cls 'pages/flashback-my-wishes' title)")" '^我的愿望$'
RAW automation_navigate --action reLaunch --url '/pages/flashback-corridor/index' >/dev/null
sleep 1.5
ck "许愿后公开卡由 2 增至 3" "$(COUNT "$WISH_CARD")" '^3$'
ck "新愿挂树可读" "$(RES automation_element_action --action text --selector "$WISH_CONTENT")" '^E2E 年度愿望$'
TRIGGER tap '{}' "$WISH_CARD"
sleep 0.8
ck "本人新愿模态带删除入口" "$(COUNT "$WISH_MODAL $WISH_DELETE")" '^1$'
RAW automation_wx_api --action mock --method showModal --result '{"confirm":false,"cancel":true}' >/dev/null
TAP "$WISH_MODAL $WISH_DELETE"
sleep 0.8
ck "取消删除保留新愿" "$(COUNT "$WISH_CARD")" '^3$'
RAW automation_wx_api --action mock --method showModal --result '{"confirm":true,"cancel":false}' >/dev/null
TAP "$WISH_MODAL $WISH_DELETE"
sleep 1.5
RAW automation_wx_api --action restore --method showModal >/dev/null
ck "确认删除后公开卡恢复 2" "$(COUNT "$WISH_CARD")" '^2$'
TRIGGER tap '{}' "$PRIVATE_FOLD"
sleep 1
ck "私愿展开箭头=收起 ▲" "$(RES automation_element_action --action text --selector "$PRIVATE_FOLD_ARROW")" '^收起 ▲$'
ck "私愿卡 1（仅自己可见）" "$(COUNT "$WISH_CARD_PRIVATE")" '^1$'
ck "本人私愿带删除" "$(COUNT "$WISH_DELETE")" '^1$'
TRIGGER tap '{}' "$PRIVATE_FOLD"
sleep 1
ck "私愿收起" "$(COUNT "$WISH_CARD_PRIVATE")" '^0$'

echo "### 11) 首程旅程（mp 版原型 F；token 面，免登录 R1）：intro→quiz→reveal→翻面写→寄出浮层"
RAW automation_navigate --action reLaunch --url '/pages/profile/index' >/dev/null
sleep 2
if [ "$(COUNT "$LOGOUT")" != "0" ]; then TAP "$LOGOUT"; sleep 1; fi
# 清 journey token（cgc.flashback_token）与首程 mock 态——段 3-9 写过的 state 不入旅程；
# nudge 已推标记一并清（段 13 要断言 welcome 引导）；入口 intent 防上次崩溃残留
RAW automation_evaluate --fn-source 'function(){ wx.removeStorageSync("cgc.e2e.flashback_mock_state"); wx.removeStorageSync("cgc.flashback_token"); wx.removeStorageSync("cgc.flashback_entry_intent"); wx.removeStorageSync("cgc.flashback_license_nudge_done"); wx.removeStorageSync("cgc.e2e.flashback_unclaimed"); wx.removeStorageSync("cgc.e2e.flashback_claim_miss") }' >/dev/null
RAW automation_navigate --action reLaunch --url '/pages/flashback-journey/index?token=e2e-flashback-token' >/dev/null
sleep 2
JOURNEY='pages/flashback-journey'
JSHUTTER=$(cls "$JOURNEY" shutter)
JLEAD=$(cls "$JOURNEY" introLead)
JQUESTION=$(cls "$JOURNEY" quizQuestion)
JOPTION=$(cls "$JOURNEY" quizOption)
JLABEL=$(cls "$JOURNEY" quizLabel)
JFEEDBACK=$(cls "$JOURNEY" quizFeedback)
JPOLAROID=$(cls "$JOURNEY" polaroid)
JNAME=$(cls "$JOURNEY" polaroidName)
JSTAMP=$(cls "$JOURNEY" polaroidStamp)
JBACK=$(cls "$JOURNEY" backTitle)
JTEXTAREA=$(cls "$JOURNEY" textarea)
JCTA=$(cls "$JOURNEY" cta)
JOVERLAY=$(cls "$JOURNEY" overlay)
JOVER_TITLE=$(cls "$JOURNEY" overlayTitle)
JOVER_PRIMARY=$(cls "$JOURNEY" overlayPrimary)
JOVER_SKIP=$(cls "$JOURNEY" overlaySkip)
JOVER_EXPECT=$(cls "$JOURNEY" overlayExpectation)
ck "落在旅程页" "$(ROUTE)" '/pages/flashback-journey/index'
ck "intro 引子=动态相对年数（R3）" "$(RES automation_element_action --action text --selector "$JLEAD")" '^[0-9]+ 年前，你写过一些答案。$'
ck "呼吸快门在" "$(COUNT "$JSHUTTER")" '^1$'
shot 11-journey-intro.png
TAP "$JSHUTTER"
sleep 1
ck "确认问句（R6）" "$(RES automation_element_action --action text --selector "$JQUESTION")" '^还记得……是哪一场吗？$'
ck "选项=正确项(池内)+2 干扰+我不记得了（2012 上海不在池内）" "$(COUNT "$JOPTION")" '^4$'
ck "正确项首位=2014.1.11 六城同日（mock 档案命中池）" "$(RES automation_element_action --action text --selector "$JOPTION $JLABEL")" '^2014\.1\.11 · 六城同日$'
TAP "$JOPTION"
sleep 1
ck "答对反馈" "$(RES automation_element_action --action text --selector "$JFEEDBACK")" '^答对了。这张照片一直在等你。$'
ck "显影卡正面=本人名" "$(RES automation_element_action --action text --selector "$JNAME")" '^王小明$'
ck "时间戳=2014.01.11 13:06" "$(RES automation_element_action --action text --selector "$JSTAMP")" '^2014\.01\.11 13:06$'
shot 11.5-journey-reveal.png
TAP "$JPOLAROID"
sleep 1.2
ck "翻面=今天背面书写" "$(RES automation_element_action --action text --selector "$JBACK")" '^今天的你 · 写完寄出$'
ck "背面 3 个输入框" "$(COUNT "$JTEXTAREA")" '^3$'
RAW automation_element_action --action input --selector "$JTEXTAREA" --value 'E2E 首程寄出' >/dev/null
TAP "$JCTA"
sleep 2
ck "寄出浮层弹出" "$(COUNT "$JOVERLAY")" '^1$'
ck "浮层标题（R29 定稿）" "$(RES automation_element_action --action text --selector "$JOVER_TITLE")" '^照片正在贴上墙。$'
ck "主按钮=微信一键收好（R27）" "$(RES automation_element_action --action text --selector "$JOVER_PRIMARY")" '^微信一键收好$'
ck "次出口=跳过，直接上墙" "$(RES automation_element_action --action text --selector "$JOVER_SKIP")" '^跳过，直接上墙$'
ck "期望管理文案" "$(RES automation_element_action --action text --selector "$JOVER_EXPECT")" '^你写下的愿望不会消失——我们会通过 Newsletter 和具体的人逐个回应。$'
shot 12-journey-overlay.png
TAP "$JOVER_SKIP"
wait_route '/pages/flashback-corridor/index' || true
ck "跳过后落长廊" "$(ROUTE)" '/pages/flashback-corridor/index'

echo "### 13) 长廊首程落地（token 态）：welcome 金句引导 + 今天格已寄出 + 点堆进场次页"
sleep 3
# welcome intent 抑制快门仪式（intent 走 storage 单次传递——switchTab 不带 query，
# router.params 永远读不到；曾因此首程落地误弹快门）
ck "首程落地不弹快门（welcome intent 抑制）" "$(COUNT "$SHUTTER_MASK")" '^0$'
ck "welcome 金句引导弹出（一次性轻推）" "$(COUNT "$NUDGE_MASK")" '^1$'
ck "引导勇气语" "$(RES automation_element_action --action text --selector "$NUDGE_LEAD")" '^你说的话，会成为别人的勇气。$'
TAP "$NUDGE_SKIP"
sleep 1
ck "先不 后引导关闭" "$(COUNT "$NUDGE_MASK")" '^0$'
ck "token 腿同档案=王小明" "$(RES automation_element_action --action text --selector "$MINICARD_NAME")" '^王小明$'
ck "dock 寄出=已寄出 ✓（首程寄出同源）" "$(RES automation_element_action --action text --selector "$DOCK_SEND")" '^已寄出 ✓$'
ck "dock 写入口带完成勾（首程写了今天）" "$(RES automation_element_action --action text --selector "$DOCK_WRITE")" '^✎ 写今天的你 ✓$'
ck "今天格点亮" "$(COUNT "$TODAY_LIT")" '^1$'
ck "今天格照片=本人名" "$(RES automation_element_action --action text --selector "$TODAY_LIT_NAME")" '^王小明$'
ck "今天格可点提示" "$(RES automation_element_action --action text --selector "$TODAY_LIT_CAP")" '^点开看你的卡 · 可保存分享$'
ck "时间帧 2（参与态完整长廊）" "$(COUNT "$CAPWHEN")" '^2$'
ck "城市堆 4" "$(COUNT "$PINPOL")" '^4$'
ck "已回来标记 3 堆（本人寄出后北京堆 2 位）" "$(COUNT "$CAPRETURNED")" '^3$'
ck "未来场次卡 3" "$(COUNT "$EVENT_CARD")" '^3$'
ck "公开愿望卡 2" "$(COUNT "$WISH_CARD")" '^2$'
ck "底部 CTA=把这一刻做成卡片" "$(RES automation_element_action --action text --selector "$CTA")" '^把这一刻做成卡片 →$'
shot 13-corridor-after-journey.png
# 堆可点（点堆=唯一格入口）：首堆=2012 上海场
TAP "$PINPOL"
wait_route '/pages/flashback-event/index' || true
ck "点堆进场次页" "$(ROUTE)" '"/pages/flashback-event/index\?key=2012-02-26-sh"'

echo "### 13.5) 场次页（E 的 event 步）：统计行+3 列网格+找回 CTA+回环三出口"
RAW automation_navigate --action reLaunch --url '/pages/flashback-event/index?key=2014-01-11-bj' >/dev/null
sleep 2
EBACK=$(cls "$EVENT" back)
ETITLE=$(cls "$EVENT" title)
ESTAT=$(cls "$EVENT" stat)
EPEOPLE_HINT=$(cls "$EVENT" peopleHint)
ECELL=$(cls "$EVENT" cell)
ELIT=$(cls "$EVENT" cardLit)
EFOG=$(cls "$EVENT" cardFog)
ECARD_NAME=$(cls "$EVENT" cardName)
EFOG_NAME=$(cls "$EVENT" cardNameFog)
EFIND=$(cls "$EVENT" cta)
ELOOP=$(cls "$EVENT" loopBtn)
ck "返回链接=‹ 时间长廊（长廊升 tabBar 后改名）" "$(RES automation_element_action --action text --selector "$EBACK")" '^‹ 时间长廊$'
ck "标题=日期 · 场次名" "$(RES automation_element_action --action text --selector "$ETITLE")" '^2014\.01\.11 · Rails Girls Beijing$'
ck "统计行三项（报名/走进教室/已回来，R12 缺数不显示口径由 mock 全值覆盖）" "$(COUNT "$ESTAT")" '^3$'
ck "报名数=344" "$(RES automation_element_action --action text --selector "$ESTAT")" '^344 位报名$'
ck "名册提示行" "$(RES automation_element_action --action text --selector "$EPEOPLE_HINT")" '^这一场的人 · 显影的是寄出了的，雾着的是还没回来的$'
ck "网格 6 人" "$(COUNT "$ECELL")" '^6$'
ck "显影卡 3（本人首程寄出 + 另两位）" "$(COUNT "$ELIT")" '^3$'
ck "雾卡 3（还没回来的）" "$(COUNT "$EFOG")" '^3$'
ck "显影卡带名字（第一格=本人王小明）" "$(RES automation_element_action --action text --selector "$ECARD_NAME")" '^王小明$'
ck "雾卡姓氏隐名" "$(RES automation_element_action --action text --selector "$EFOG_NAME")" '^杨\*\*$'
ck "找回 CTA" "$(RES automation_element_action --action text --selector "$EFIND")" '^你也在这一场？找回你的那一张 →$'
ck "回环三出口（下一场/回到今天/看看未来）" "$(COUNT "$ELOOP")" '^3$'
ck "下一场=最近可报名场" "$(RES automation_element_action --action text --selector "$ELOOP")" '^下一场:Agent 入门工作坊 →$'
shot 13.5-event-grid.png

echo "### 14) 三级视角（R32）：路人围观 → 登录未匹配给出下一步 → 自动认领闭环"
# 14a 路人态：清 token/登录 → 公开金句首页，登录找回
RAW automation_evaluate --fn-source 'function(){ wx.removeStorageSync("cgc.flashback_token"); wx.setStorageSync("cgc.e2e.flashback_unclaimed", "1"); wx.setStorageSync("cgc.e2e.flashback_claim_miss", "1") }' >/dev/null
RAW automation_navigate --action reLaunch --url '/pages/profile/index' >/dev/null
sleep 2
if [ "$(COUNT "$LOGOUT")" != "0" ]; then TAP "$LOGOUT"; sleep 1; fi
RAW automation_navigate --action reLaunch --url '/pages/flashback-corridor/index' >/dev/null
sleep 3
ck "访客找回入口" "$(RES automation_element_action --action text --selector "$GUEST_RECOVER")" '^找回你的那一张 →$'
ck "访客有公开金句卡" "$(COUNT "$GUEST_QUOTE")" '^1$'
ck "访客有金句墙入口" "$(COUNT "$GUEST_VOICES")" '^1$'
ck "访客有许愿树入口" "$(COUNT "$GUEST_WISHES")" '^1$'
ck "访客无个人卡/城市钉/愿望列表/场次卡" "$(COUNT "$CARDDOCK")/$(COUNT "$CITY_PIN")/$(COUNT "$WISH_CARD")/$(COUNT "$EVENT_CARD")" '^0/0/0/0$'
ck "访客不渲染个人今天空位" "$(COUNT "$TODAY_VACANT_TEXT")" '^0$'
shot 14-corridor-viewer.png

# 14b 登录但库内未匹配（claim miss）→ 公开首页保留，找回区提供写愿望出口。
RAW automation_navigate --action reLaunch --url '/pages/login/index' >/dev/null
sleep 2
TAP "$LOGIN_BUTTON"
sleep 1
TAP "$DIALOG_PRIMARY"
wait_route '/pages/profile/index' || true
RAW automation_navigate --action reLaunch --url '/pages/flashback-corridor/index' >/dev/null
sleep 3.5
ck "未匹配可直接写愿望" "$(RES automation_element_action --action text --selector "$GUEST_RECOVER")" '^写下我的愿望 →$'
ck "未匹配无卡 dock（不伪造参与态）" "$(COUNT "$CARDDOCK")" '^0$'
ck "未匹配显示公开首页而非统计长廊" "$(COUNT "$GUEST_QUOTE")/$(COUNT "$CAPWHEN")" '^1/0$'
shot 14.5-corridor-claim-miss.png

# 14c 自动认领（claim 命中）→ 直接进参与态（member 转变 → 快门仪式层）
RAW automation_evaluate --fn-source 'function(){ wx.removeStorageSync("cgc.e2e.flashback_claim_miss") }' >/dev/null
RAW automation_navigate --action reLaunch --url '/pages/flashback-corridor/index' >/dev/null
sleep 4
ck "认领后 member 转变 → 快门仪式层出现" "$(COUNT "$SHUTTER_MASK")" '^1$'
TAP "$SHUTTER_BTN"
sleep 1
ck "点按解散" "$(COUNT "$SHUTTER_MASK")" '^0$'
ck "认领后卡 dock 恢复" "$(COUNT "$CARDDOCK")" '^1$'
ck "认领档案=王小明" "$(RES automation_element_action --action text --selector "$MINICARD_NAME")" '^王小明$'
ck "参与态时间帧 2" "$(COUNT "$CAPWHEN")" '^2$'
ck "参与态恢复未来场次卡 3" "$(COUNT "$EVENT_CARD")" '^3$'
ck "参与态恢复愿望卡 2" "$(COUNT "$WISH_CARD")" '^2$'
ck "参与态恢复城市钉 3" "$(COUNT "$CITY_PIN")" '^3$'
ck "收尾 CTA=把这一刻做成卡片" "$(RES automation_element_action --action text --selector "$CTA")" '^把这一刻做成卡片 →$'
shot 15-corridor-claimed.png
RAW automation_evaluate --fn-source 'function(){ wx.removeStorageSync("cgc.e2e.flashback_unclaimed"); wx.removeStorageSync("cgc.e2e.workspace_access_denied") }' >/dev/null


echo "### 10) 隔离取证：mock 不走网络 + 无运行时报错"
NET=$(RAW get_simulator_network --command 'grep -i graphql' | sed -n 's/.*"result": "\(.*\)"/\1/p' | tail -1)
ck "network 无 graphql 请求（mock 在 JS 层拦截）" "${NET:-（空）}" '^（空）$'
# DevTools 自动化导航的系统错误与页面错误分开；按完整错误事件过滤，
# 避免同批次出现真实页面错误时连带吞掉。
CON_PAGE=$(RAW get_simulator_console --command 'grep -i -e error -e fail' | node -e '
  const raw = require("node:fs").readFileSync(0, "utf8")
  try {
    const result = JSON.parse(raw.slice(raw.indexOf("{"))).result
    // 命中 1 行 → 工具已解析成数组；多行 → 每行一条 JSON 数组文本（grep 分隔符 -- 跳过）
    const events = Array.isArray(result) ? [result] : String(result ?? "").split("\n")
      .map((line) => line.replace(/^[0-9]+:/, "").trim())
      .filter((line) => line && line !== "--")
      .map((line) => { try { return JSON.parse(line) } catch { return [line] } })
    const noise = ([level, ...rest]) => {
      const message = rest.join(" ")
      return level === "[error]" && (
        message.includes("appLaunch with non-empty page stack") ||
        (message.includes("SystemError (appServiceSDKScriptError)") &&
          /routeDone with a webviewId [0-9]+ is not found/.test(message) &&
          message.includes("WAServiceMainContext.js")))
    }
    process.stdout.write(events.filter((event) => !noise(event))
      .map((event) => JSON.stringify(event))
      .filter((line) => /\[error\]|\[warn\]|fail/i.test(line)).join("\n"))
  } catch { process.stdout.write("console parse failure") }
')
ck "console 无页面运行时 error（已剔 devtools 导航噪音）" "${CON_PAGE:-（空）}" '^（空）$'

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✅ flashback-journey E2E 全绿：$PASS 项断言通过（截图在 $ART/）"
else
  echo "❌ $FAIL 项失败（$PASS 项通过）"
fi
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
