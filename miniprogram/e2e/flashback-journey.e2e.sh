#!/usr/bin/env bash
# 「我的闪念间」旅程 E2E（小程序 / weapp 模拟器，本地回归用，**不进 CI**）
#
# 覆盖（对齐 U9/R28 flashback 回访正门 + 批次二 mp 版原型 F）：
#   1. 未登录深链直达 → 登录引导面（mock: flashback_auth_required → SessionExpiredError → need_login，P1）
#   2. mock 登录链（手机号授权 passthrough）→ profile「我的」入口 → 闪念间页
#   3. 我的卡：当年正面（句子级雾面）+ 今天背面（编辑/保存回显）+ 金句授权三档切换
#   4. 雾化编辑：点按雾面句 → 解雾（R16/KTD4 本人视图原文永远完整）
#   5. 行动板：四态卡各一次、已附议在前、已成场卡 goEvent 直链
#  批次二：
#   11. 首程旅程（token 面免登录）：intro→quiz→reveal→翻面写→寄出浮层（R27/R29）
#   13. 长廊：垂直墙 + 城市堆 + ⚡今天格 + 未来行动卡（R12/R34）
#   13.5 场次页：统计行 + 3 列网格（显影/雾卡）+ 找回 CTA
#   14. 三级视角（R32）：路人围观 → 未匹配找回引导 → 登录自动认领闭环
#
# 为什么不在 CI：需要微信开发者工具 GUI（已登录）+ wechatide CLI，见
# miniprogram/AGENTS.md「E2E」一节。web 端 E2E 走 ego-browser，与本脚本无关。
#
# 已知边界（首跑 2026-09-18 实测；同日修复后附议闭环已进段 9.5）：
#   - 附议按钮曾无法自动化触达（element_action 多匹配只作用于 DOM 第一个）。
#     修复：行动卡容器挂四态类名（P4）后，后代选择器 `.forming卡容器 .endorseButton`
#     唯一定位 + automation_wx_api mock showActionSheet（tapIndex 0）走通角色选择。
#   - 行动板空态 / not_bound 态：mock capsule 固定四卡 + 登录即绑定，无法构造。
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
# 故运行时从 dist 产物里解析，不写死。另：wechatide 的 --wait-for-selector 是
# 「执行**前**等待」，用它等本步要操作的元素，不要当导航后的等待用。
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
# 在唯一节点上派发自定义事件（radio-group 等无类名原生容器的事件驱动交互）
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

FLASHBACK='pages/flashback'
LOGIN='pages/login'
PROFILE='pages/profile'

# 页面级类名
EYEBROW=$(cls "$FLASHBACK" eyebrow)
HEADLINE=$(cls "$FLASHBACK" headline)
SUBLINE=$(cls "$FLASHBACK" subline)
WALL_BADGE=$(cls "$FLASHBACK" wallBadge)
POLAROID_LABEL=$(cls "$FLASHBACK" polaroidLabel)
CARD_FACE_TITLE=$(cls "$FLASHBACK" cardFaceTitle)
ANSWER_META=$(cls "$FLASHBACK" answerMeta)
SENTENCE=$(cls "$FLASHBACK" sentence)
SENTENCE_FOGGED=$(cls "$FLASHBACK" sentenceFogged)
TODAY_EMPTY=$(cls "$FLASHBACK" todayEmpty)
TODAY_TEXT=$(cls "$FLASHBACK" todayText)
EDITOR_TOGGLE=$(cls "$FLASHBACK" editorToggle)
TEXTAREA=$(cls "$FLASHBACK" textarea)
SAVE_BUTTON=$(cls "$FLASHBACK" saveButton)
LICENSE_CARD=$(cls "$FLASHBACK" licenseCard)
LICENSE_OPTION=$(cls "$FLASHBACK" licenseOption)
LICENSE_ACTIVE=$(cls "$FLASHBACK" licenseOptionActive)
LICENSE_LABEL=$(cls "$FLASHBACK" licenseLabel)
BOARD_HINT=$(cls "$FLASHBACK" boardHint)
ACTION_CARD=$(cls "$FLASHBACK" actionCard)
ACTION_TITLE=$(cls "$FLASHBACK" actionTitle)
ACTION_META=$(cls "$FLASHBACK" actionMeta)
ACTION_STATUS=$(cls "$FLASHBACK" actionStatus)
ENDORSE_BUTTON=$(cls "$FLASHBACK" endorseButton)
ENDORSE_PLAIN=$(cls "$FLASHBACK" endorseButtonPlain)
CITY_PINS=$(cls "$FLASHBACK" cityPins)
CITY_PIN=$(cls "$FLASHBACK" cityPin)
QUOTE_PICKER=$(cls pages/flashback 'quotePicker')
QUOTE_CANDIDATE=$(cls pages/flashback 'quoteCandidate')
QUOTE_CANDIDATE_ACTIVE=$(cls pages/flashback 'quoteCandidateActive')
SHARE_OPTIN=$(cls pages/flashback 'shareOptIn')
LIKE_BADGE=$(cls pages/flashback 'likeBadge')
CITY_PIN_ALL=$(cls "$FLASHBACK" cityPinAll)
CITY_PIN_ACTIVE=$(cls "$FLASHBACK" cityPinActive)
STATUS_SCHED=$(cls "$FLASHBACK" scheduled)
STATUS_DONE=$(cls "$FLASHBACK" done)
STATUS_PROP=$(cls "$FLASHBACK" proposed)
STATUS_FORM=$(cls "$FLASHBACK" forming)
ROLES_ROW=$(cls "$FLASHBACK" rolesRow)
# 登录/我的页类名
LOGIN_BUTTON=$(cls "$LOGIN" loginButton)
DIALOG_PRIMARY=$(cls "$LOGIN" dialogPrimary)
OPENCLACKY=$(cls "$PROFILE" openclacky)
OPENCLACKY_TEXT=$(cls "$PROFILE" openclackyText)
LOGOUT=$(cls "$PROFILE" logout)
# 状态面（P1 后未登录直达渲染登录引导而非 PageState error 面）
STATE_TEXT=$(cls "$FLASHBACK" stateText)
STATE_ACTION=$(cls "$FLASHBACK" stateAction)

echo "### 0) 清态：退出残留登录 + 清 FLASHBACK_MOCK_STATE（mock 持久档，P2；不清则雾面/授权档/附议跨跑残留）"
RAW automation_navigate --action reLaunch --url '/pages/profile/index' >/dev/null
sleep 2
# 清 storage 放 reLaunch 后（runtime 已就绪）；刚开窗口时 evaluate 可能还没就绪，重试一次
cleared=0
for _ in 1 2; do
  if RAW automation_evaluate --fn-source 'function(){ wx.removeStorageSync("cgc.e2e.flashback_mock_state") }' \
    | grep -q '"success": true'; then cleared=1; break; fi
  sleep 1.5
done
[ "$cleared" = 1 ] || { echo "✗ 清 FLASHBACK_MOCK_STATE 失败（automation_evaluate）" >&2; exit 2; }
if [ "$(COUNT "$LOGOUT")" != "0" ]; then
  TAP "$LOGOUT"
  sleep 1
fi
ck "清态后未登录（无退出按钮）" "$(COUNT "$LOGOUT")" '^0$'

echo "### 1) 未登录深链直达闪念间 → 登录引导面（P1：flashback_auth_required → SessionExpiredError → need_login）"
RAW automation_navigate --action reLaunch --url '/pages/flashback/index' >/dev/null
sleep 2
ck "落在 flashback 页" "$(ROUTE)" '/pages/flashback/index'
ck "引导文案=登录后可见（不再渲染 error 面）" "$(RES automation_element_action --action text --selector "$STATE_TEXT")" '^登录后可以看到你的闪念间档案$'
ck "引导面有去登录按钮" "$(COUNT "$STATE_ACTION")" '^1$'
shot 01-flashback-not-logged-in.png

echo "### 2) mock 登录链（手机号授权 passthrough，不碰真实凭据）"
RAW automation_navigate --action reLaunch --url '/pages/login/index' >/dev/null
sleep 2
TAP "$LOGIN_BUTTON"
sleep 1
TAP "$DIALOG_PRIMARY"
wait_route '/pages/profile/index' || true
ck "登录成功落「我的」tab" "$(ROUTE)" '/pages/profile/index'
shot 02-after-login-profile.png

echo "### 3) profile「我的」入口 → 闪念间（AE9 小程序侧入口可达）"
ck "入口区块（闪念间/OpenClacky 复用同款卡样式，各一）" "$(COUNT "$OPENCLACKY")" '^2$'
ck "入口文案（当年的拍立得…）" "$(RES automation_element_action --action text --selector "$OPENCLACKY_TEXT")" '当年的拍立得、今天的回答、你附议的行动卡。'
TAP "$OPENCLACKY"
wait_route '/pages/flashback/index' || true
ck "入口进入闪念间" "$(ROUTE)" '/pages/flashback/index'
shot 03-flashback-from-profile.png

echo "### 3.5) 我的卡两态（用户定稿 ① / 第 3b 件）：默认合着卡面 → 点击卡面 3D 翻转看正反两面 → 合上"
POLAROID_COVER=$(cls pages/flashback 'polaroidCover')
COVER_NAME=$(cls pages/flashback 'coverName')
FLIP_OPEN=$(cls pages/flashback 'polaroidFlipOpen')
FOLD_BACK=$(cls pages/flashback 'foldBackButton')
CARD_FLIP=$(cls pages/flashback 'cardFlip')
ck "默认=合着卡面（容器在）" "$(COUNT "$POLAROID_COVER")" '^1$'
ck "卡面全名" "$(RES automation_element_action --action text --selector "$COVER_NAME")" '^王小明$'
ck "默认内容区不渲染（答案在卡面后）" "$(COUNT "$FLIP_OPEN")" '^0$'
ck "3D 翻面容器在（第 3b 件：点击卡面翻转）" "$(COUNT "$CARD_FLIP")" '^1$'
TAP "$POLAROID_COVER"
sleep 1
ck "点开后正反两面容器出现" "$(COUNT "$FLIP_OPEN")" '^1$'
shot 035-flashback-flipped.png
ck "合上按钮出现" "$(COUNT "$FOLD_BACK")" '^1$'
TAP "$FOLD_BACK"
sleep 0.6
ck "合上回卡面态" "$(COUNT "$POLAROID_COVER")" '^1$'
ck "合上后内容区收起" "$(COUNT "$FLIP_OPEN")" '^0$'
TAP "$POLAROID_COVER"
sleep 0.8
echo "### 4) 我的卡：当年正面（雾面句）+ 今天背面 + 头部口径（R3/R2/R11）"
ck "eyebrow" "$(RES automation_element_action --action text --selector "$EYEBROW")" '^IN A FLASH · 闪念间$'
ck "headline=本人 · 相对年数" "$(RES automation_element_action --action text --selector "$HEADLINE")" '王小明 · [0-9]+ 年前的你'
ck "subline=记忆线 · 城市" "$(RES automation_element_action --action text --selector "$SUBLINE")" '^记忆线 · 北京$'
ck "寄出态默认未寄出" "$(RES automation_element_action --action text --selector "$WALL_BADGE")" '^还未寄出（可在网页端寄出）$'
ck "拍立得标签=申请日" "$(RES automation_element_action --action text --selector "$POLAROID_LABEL")" '^POLAROID · 2014-01-11$'
ck "两行卡面标题（正面+背面）" "$(COUNT "$CARD_FACE_TITLE")" '^2$'
ck "雾化操作提示" "$(RES automation_element_action --action text --selector "$ANSWER_META")" '点按句子切换雾面：雾面句对外隐藏，你这里永远完整'
ck "切句=3 句" "$(COUNT "$SENTENCE")" '^3$'
ck "雾面句=1 句（mock fogSpans [0,7) 只罩首句）" "$(COUNT "$SENTENCE_FOGGED")" '^1$'
ck "本人视图首句永远完整（KTD4）" "$(RES automation_element_action --action text --selector "$SENTENCE")" '^我在盛大做测试。'
ck "今天背面三行均未写" "$(COUNT "$TODAY_EMPTY")" '^3$'
ck "编辑入口文案" "$(RES automation_element_action --action text --selector "$EDITOR_TOGGLE")" '^编辑今天的你$'
# R36：点赞徽章只在「上墙且有点赞」时出现——mock 未寄出，故此处不渲染（判据在 domain 单测钉住）
ck "未寄出：无点赞徽章（R36）" "$(COUNT "$LIKE_BADGE")" '^0$'
shot 04-flashback-my-card.png

echo "### 5) 雾化编辑：点按雾面句 → 解雾（R16 句子级开关）"
TAP "$SENTENCE_FOGGED"
sleep 1.5
ck "点按后雾面清空" "$(COUNT "$SENTENCE_FOGGED")" '^0$'
shot 05-flashback-fog-cleared.png

echo "### 6) 今天背面：编辑 → 填写 → 保存回显"
TAP "$EDITOR_TOGGLE"
sleep 1
ck "编辑态 3 个输入框" "$(COUNT "$TEXTAREA")" '^3$'
ck "保存按钮出现" "$(COUNT "$SAVE_BUTTON")" '^1$'
RAW automation_element_action --action input --selector "$TEXTAREA" --value 'E2E 闪念间回访' >/dev/null
TAP "$SAVE_BUTTON"
sleep 2
ck "保存后退回展示态" "$(COUNT "$TEXTAREA")" '^0$'
ck "回显=刚写的现在在做什么" "$(RES automation_element_action --action text --selector "$TODAY_TEXT")" '^E2E 闪念间回访$'
ck "保存重载后雾面仍清空（mock state 持久回读，P2）" "$(COUNT "$SENTENCE_FOGGED")" '^0$'
shot 06-flashback-today-saved.png

echo "### 7) 金句授权三档（R31）：默认关 + trigger 切匿名"
ck "授权卡存在" "$(COUNT "$LICENSE_CARD")" '^1$'
ck "三档选项" "$(COUNT "$LICENSE_OPTION")" '^3$'
ck "默认选中恰好一档" "$(COUNT "$LICENSE_ACTIVE")" '^1$'
ck "默认档=不授权" "$(RES automation_element_action --action text --selector "$LICENSE_ACTIVE $LICENSE_LABEL")" '^不授权$'
# radio 无类名差异可定位第 2 个，radio-group 是页面唯一原生容器：
# 在其上派发 change 事件（与真机点 radio 同一事件源）
TRIGGER change '{"value":"anonymous"}' 'radio-group'
sleep 1.5
ck "切换后选中=匿名金句" "$(RES automation_element_action --action text --selector "$LICENSE_ACTIVE $LICENSE_LABEL")" '^匿名金句$'
# R35 选句器：匿名档下展开候选句（按句切分、排除雾面段——mock 首句带雾面 → 2 句候选）；
# 未圈选 = 不上墙，所以授权提交发生在点句这一步
ck "选句器展开（R35）" "$(COUNT "$QUOTE_PICKER")" '^1$'
# 段 5 已把唯一雾面句解开 → 3 句全部可作候选（雾面排除判据在 domain 单测钉住）
ck "候选句=3（雾面已在段 5 解开）" "$(COUNT "$QUOTE_CANDIDATE")" '^3$'
ck "默认无圈选高亮" "$(COUNT "$QUOTE_CANDIDATE_ACTIVE")" '^0$'
TAP "$QUOTE_CANDIDATE"
sleep 1.5
ck "圈选后高亮恰一句" "$(COUNT "$QUOTE_CANDIDATE_ACTIVE")" '^1$'
shot 07-flashback-quote-anonymous.png

echo "### 7.5) 分享三件（用户定稿 ③）：入口按钮 + sheet 三入口 + 取消收起"
SHARE_BUTTON=$(cls pages/flashback 'shareButton')
SHARE_SHEET=$(cls pages/flashback 'shareSheet')
SHARE_CANCEL=$(cls pages/flashback 'shareCancel')
SHARE_ENTRY=$(cls pages/flashback 'shareEntry')
ck "分享入口按钮" "$(COUNT "$SHARE_BUTTON")" '^1$'
TAP "$SHARE_BUTTON"
sleep 0.8
ck "分享 sheet 弹出" "$(COUNT "$SHARE_SHEET")" '^1$'
ck "三入口（好友/朋友圈/保存）" "$(COUNT "$SHARE_ENTRY")" '^3$'
# R37 分享 opt-in：已授权（上一步圈选开了匿名档）→ 显示且为锁定态（分享改不了档位）
ck "分享 opt-in 行出现（R37）" "$(COUNT "$SHARE_OPTIN")" '^1$'
shot 075-share-sheet.png
TAP "$SHARE_CANCEL"
sleep 0.6
ck "取消后 sheet 收起" "$(COUNT "$SHARE_SHEET")" '^0$'

echo "### 8) 行动板：四态卡各一次 + 已附议在前（R13 分组）"
ck "行动板提示" "$(RES automation_element_action --action text --selector "$BOARD_HINT")" '^已附议的卡排前面；附议后成场时会收到通知$'
ck "四张行动卡" "$(COUNT "$ACTION_CARD")" '^4$'
# P4 起容器也挂四态类（.scheduled 等首匹配变成整卡容器）——徽章用
# `<状态卡容器> .actionStatus` 后代选择器唯一命中该卡状态徽章
ck "已成场徽章" "$(RES automation_element_action --action text --selector "$STATUS_SCHED $ACTION_STATUS")" '^已成场$'
ck "已落地徽章" "$(RES automation_element_action --action text --selector "$STATUS_DONE $ACTION_STATUS")" '^已落地$'
ck "提议中徽章" "$(RES automation_element_action --action text --selector "$STATUS_PROP $ACTION_STATUS")" '^提议中$'
ck "附议中徽章" "$(RES automation_element_action --action text --selector "$STATUS_FORM $ACTION_STATUS")" '^附议中$'
ck "第一张卡=已附议的已成场卡（分组在前）" "$(RES automation_element_action --action text --selector "$ACTION_TITLE")" '^Python 共学场$'
ck "首卡动作=成场了，去报名（goEvent）" "$(RES automation_element_action --action text --selector "$ENDORSE_BUTTON")" '^成场了，去报名$'
ck "已认领角色行（首卡）" "$(RES automation_element_action --action text --selector "$ROLES_ROW")" '^已认领：宣传拉人、场地资源$'
ck "附议按钮共 3 张卡可见（sched+proposed+forming）" "$(COUNT "$ENDORSE_BUTTON")" '^3$'
ck "无人处于已附议素按钮态" "$(COUNT "$ENDORSE_PLAIN")" '^0$'
shot 08-flashback-action-board.png

echo "### 8.5) 城市钉筛选（R34）：点城市 → 行动板只剩该城；回全部恢复"
# mock cities 字节序 [上海,北京,天津,广州,杭州]（批次二并入名册城市）：.cityPin 第一匹配=上海钉（全部钉为独立类 cityPinAll）
ck "城市钉条渲染（全部 + 五城）" "$(COUNT "$CITY_PIN")" '^5$'
ck "全部钉唯一" "$(COUNT "$CITY_PIN_ALL")" '^1$'
ck "初始选中钉=全部（恰一选中）" "$(COUNT "$CITY_PIN_ACTIVE")" '^1$'
ck "全部钉带选中态" "$(RES automation_element_action --action text --selector "$CITY_PIN_ALL$CITY_PIN_ACTIVE")" '^全部$'
TAP "$CITY_PIN"
sleep 2
ck "筛上海后行动板只剩 1 卡" "$(COUNT "$ACTION_CARD")" '^1$'
ck "该卡=上海已成场卡（名册只含该城）" "$(RES automation_element_action --action text --selector "$ACTION_META")" '^上海 · 已有 12 人附议$'
ck "选中钉切到上海" "$(RES automation_element_action --action text --selector "$CITY_PIN_ACTIVE")" '^上海$'
ck "钉条不随过滤收缩（仍 5 城钉）" "$(COUNT "$CITY_PIN")" '^5$'
shot 08.5-flashback-city-filtered.png
TAP "$CITY_PIN_ALL"
sleep 2
ck "回全部恢复四张卡" "$(COUNT "$ACTION_CARD")" '^4$'
ck "选中钉回全部" "$(RES automation_element_action --action text --selector "$CITY_PIN_ALL$CITY_PIN_ACTIVE")" '^全部$'

echo "### 9) 已成场卡 goEvent 直链（R13：不在闪念间内闭环）"
TAP "$ENDORSE_BUTTON"
wait_route '/pages/event-detail/index' || true
ck "直链落活动详情（id=event-1）" "$(ROUTE)" '"/pages/event-detail/index\?id=event-1&kind=event"'
shot 09-flashback-goevent-link.png
RAW automation_navigate --action navigateBack >/dev/null
sleep 2.5
ck "返回闪念间授权档回读=匿名（capsule.me.quoteLevel，P3）" "$(RES automation_element_action --action text --selector "$LICENSE_ACTIVE $LICENSE_LABEL")" '^匿名金句$'

echo "### 9.5) 附议闭环（P4）：forming 卡附议 → showActionSheet mock → 计数 +1"
# 行动卡容器挂四态类名（P4）后 `.forming .endorseButton` 唯一命中 forming 卡按钮
# （.forming 的另一处在状态徽章 Text 上，其内无按钮）。showActionSheet mock
# 已实测可用：tapIndex 0 = 组织者（ENDORSE_ROLES[0]）。
RAW automation_wx_api --action mock --method showActionSheet --result '{"tapIndex":0,"errMsg":"showActionSheet:ok"}' >/dev/null
TAP "$STATUS_FORM $ENDORSE_BUTTON"
sleep 2.5
ck "附议后 forming 卡计数 +1（4→5）" "$(RES automation_element_action --action text --selector "$STATUS_FORM $ACTION_META")" '^北京 · 已有 5 人附议$'
ck "forming 卡附议后=已附议素按钮态" "$(COUNT "$ENDORSE_PLAIN")" '^1$'
shot 10-flashback-endorsed.png

echo "### 11) 首程旅程（mp 版原型 F；token 面，免登录 R1）：intro→quiz→reveal→翻面写→寄出浮层"
RAW automation_navigate --action reLaunch --url '/pages/profile/index' >/dev/null
sleep 2
if [ "$(COUNT "$LOGOUT")" != "0" ]; then TAP "$LOGOUT"; sleep 1; fi
# 清 journey token（cgc.flashback_token）与首程 mock 态——段 3-9 写过的 state 不入旅程
RAW automation_evaluate --fn-source 'function(){ wx.removeStorageSync("cgc.e2e.flashback_mock_state"); wx.removeStorageSync("cgc.flashback_token"); wx.removeStorageSync("cgc.e2e.flashback_unclaimed"); wx.removeStorageSync("cgc.e2e.flashback_claim_miss") }' >/dev/null
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
ck "选项=正确项(池内)+3 干扰+我不记得了" "$(COUNT "$JOPTION")" '^5$'
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

echo "### 13) 长廊（mp 版原型 F corridor；token 态=R12/R34）：垂直墙+城市堆+今天格+未来卡"
CORRIDOR='pages/flashback-corridor'
CTITLE=$(cls "$CORRIDOR" title)
CHINT=$(cls "$CORRIDOR" hint)
CFRAME_WHEN=$(cls "$CORRIDOR" frameWhen)
CPILE=$(cls "$CORRIDOR" pile)
CPILE_CARD=$(cls "$CORRIDOR" pileCard)
CFRAME_LABEL=$(cls "$CORRIDOR" frameLabel)
CPILE_COUNT=$(cls "$CORRIDOR" pileCount)
CRETURNED=$(cls "$CORRIDOR" frameReturned)
CTODAY_SUB=$(cls "$CORRIDOR" todaySub)
CFUTURE_CARD=$(cls "$CORRIDOR" futureCard)
CCTA=$(cls "$CORRIDOR" cta)
ck "墙头「闪念间 · 时间长廊」（用户定稿改名）" "$(RES automation_element_action --action text --selector "$CTITLE")" '^闪念间 · 时间长廊$'
ck "下滑=时间前进提示" "$(RES automation_element_action --action text --selector "$CHINT")" '^↓ 下滑 = 时间前进：顶上是当年，底部是等你的未来 · 点任一格进入那一场$'
ck "帧标 4 = 2 过去帧 + ⚡今天格 + 未来帧（升序）" "$(COUNT "$CFRAME_WHEN")" '^4$'
ck "第一帧=2012.02.26（顶上是更早的）" "$(RES automation_element_action --action text --selector "$CFRAME_WHEN")" '^2012\.02\.26'
ck "城市堆 4（上海场 1 城 + 北京场 北京/上海/广州 3 堆，上限 4）" "$(COUNT "$CPILE")" '^4$'
ck "首堆计数=上海 · 3 位" "$(RES automation_element_action --action text --selector "$CPILE_COUNT")" '^上海 · 3 位$'
ck "首帧叙事标签=一切的开始（原型 D ia-frame-label）" "$(RES automation_element_action --action text --selector "$CFRAME_LABEL")" '^一切的开始$'
ck "第一帧（上海场）已回来=2 位" "$(RES automation_element_action --action text --selector "$CRETURNED")" '^2 位已回来$'
ck "今天格=你刚寄出的照片" "$(RES automation_element_action --action text --selector "$CTODAY_SUB")" '^你刚寄出的照片$'
ck "未来行动卡 4 张" "$(COUNT "$CFUTURE_CARD")" '^4$'
ck "序列终点 CTA=把这一刻做成卡片" "$(RES automation_element_action --action text --selector "$CCTA")" '^把这一刻做成卡片 →$'
shot 13-corridor.png
# 堆可点（用户定稿收尾：文字链接已删，点堆=唯一格入口）
TAP "$CPILE_CARD"
wait_route '/pages/flashback-event/index' || true
ck "点堆进场次页" "$(ROUTE)" '"/pages/flashback-event/index\?key=2012-02-26-sh"'

echo "### 13.5) 场次页（E 的 event 步）：统计行+3 列网格+找回 CTA"
RAW automation_navigate --action reLaunch --url '/pages/flashback-event/index?key=2014-01-11-bj' >/dev/null
sleep 2
EVENT='pages/flashback-event'
EBACK=$(cls "$EVENT" back)
ETITLE=$(cls "$EVENT" title)
ESTAT=$(cls "$EVENT" stat)
ECELL=$(cls "$EVENT" cell)
ELIT=$(cls "$EVENT" cardLit)
EFOG=$(cls "$EVENT" cardFog)
EFOG_NAME=$(cls "$EVENT" cardNameFog)
EFIND=$(cls "$EVENT" cta)
ck "返回链接" "$(RES automation_element_action --action text --selector "$EBACK")" '^‹ 时间胶囊$'
ck "标题=日期 · 场次名" "$(RES automation_element_action --action text --selector "$ETITLE")" '^2014\.01\.11 · Rails Girls Beijing$'
ck "统计行三项（报名/走进教室/已回来，R12 缺数不显示口径由 mock 全值覆盖）" "$(COUNT "$ESTAT")" '^3$'
ck "报名数=344" "$(RES automation_element_action --action text --selector "$ESTAT")" '^344 位报名$'
ck "网格 6 人" "$(COUNT "$ECELL")" '^6$'
ck "显影卡 3（寄出了的）" "$(COUNT "$ELIT")" '^3$'
ck "雾卡 3（还没回来的）" "$(COUNT "$EFOG")" '^3$'
ECARD_NAME=$(cls "$EVENT" cardName)
ck "显影卡带名字（第一格=本人王小明）" "$(RES automation_element_action --action text --selector "$ECARD_NAME")" '^王小明$'
ck "雾卡姓氏隐名" "$(RES automation_element_action --action text --selector "$EFOG_NAME")" '^杨\*\*$'
ck "找回 CTA" "$(RES automation_element_action --action text --selector "$EFIND")" '^你也在这一场？找回你的那一张 →$'
shot 13.5-event-grid.png

echo "### 14) 三级视角（R32）：路人围观 → 登录未匹配引导 → 自动认领闭环"
# 14a 路人态：清 token/登录 → 公开统计长廊（无名单），登录引导
RAW automation_evaluate --fn-source 'function(){ wx.removeStorageSync("cgc.flashback_token"); wx.setStorageSync("cgc.e2e.flashback_unclaimed", "1"); wx.setStorageSync("cgc.e2e.flashback_claim_miss", "1") }' >/dev/null
RAW automation_navigate --action reLaunch --url '/pages/profile/index' >/dev/null
sleep 2
if [ "$(COUNT "$LOGOUT")" != "0" ]; then TAP "$LOGOUT"; sleep 1; fi
RAW automation_navigate --action reLaunch --url '/pages/flashback-corridor/index' >/dev/null
sleep 2.5
CGUIDE=$(cls "$CORRIDOR" guideText)
CVIEWER=$(cls "$CORRIDOR" viewerHint)
ck "路人态=登录引导文案" "$(RES automation_element_action --action text --selector "$CGUIDE")" '^你也在这些照片里吗？登录后我们帮你找。$'
ck "路人 CTA=微信一键登录找回" "$(RES automation_element_action --action text --selector "$CCTA")" '^微信一键登录，找回你的那一张 →$'
ck "路人帧=公开统计（2012 场在，无名册内容）" "$(RES automation_element_action --action text --selector "$CFRAME_WHEN")" '^2012\.02\.26'
ck "路人态无行动卡（R32 无未授权内容）" "$(COUNT "$CFUTURE_CARD")" '^0$'
shot 14-corridor-viewer.png

# 14b 登录但库内未匹配（claim miss）→ 「找回你的那一张」会话引导
RAW automation_navigate --action reLaunch --url '/pages/login/index' >/dev/null
sleep 2
TAP "$LOGIN_BUTTON"
sleep 1
TAP "$DIALOG_PRIMARY"
wait_route '/pages/profile/index' || true
RAW automation_navigate --action reLaunch --url '/pages/flashback-corridor/index' >/dev/null
sleep 3
ck "未匹配 → 找回引导文案" "$(RES automation_element_action --action text --selector "$CGUIDE")" '^我们还没找到你的档案——收到过我们的链接就从链接打开完成首程，或用网页端「闪念间」凭手机号找回。$'
shot 14.5-corridor-recover.png

# 14c 自动认领（claim 命中）→ 直接进参与态
RAW automation_evaluate --fn-source 'function(){ wx.removeStorageSync("cgc.e2e.flashback_claim_miss") }' >/dev/null
RAW automation_navigate --action reLaunch --url '/pages/flashback-corridor/index' >/dev/null
sleep 3.5
ck "自动认领后=参与态长廊（帧标恢复 4：2 过去帧+今天+未来）" "$(COUNT "$CFRAME_WHEN")" '^4$'
ck "参与态恢复行动卡" "$(COUNT "$CFUTURE_CARD")" '^4$'
ck "收尾：路人提示不再出现（已认领）" "$(COUNT "$CVIEWER")" '^0$'
shot 15-corridor-claimed.png
RAW automation_evaluate --fn-source 'function(){ wx.removeStorageSync("cgc.e2e.flashback_unclaimed") }' >/dev/null


echo "### 10) 隔离取证：mock 不走网络 + 无运行时报错"
NET=$(RAW get_simulator_network --command 'grep -i graphql' | sed -n 's/.*"result": "\(.*\)"/\1/p' | tail -1)
ck "network 无 graphql 请求（mock 在 JS 层拦截）" "${NET:-（空）}" '^（空）$'
# 「appLaunch with non-empty page stack」是 devtools 自动化导航的已知系统噪音
# （WAService errorReport），与页面运行时无关，剔除后再断言
CON=$(RAW get_simulator_console --command 'grep -i -e error -e fail' | sed -n 's/.*"result": "\(.*\)"/\1/p' | tail -1)
CON_PAGE=$(printf '%s' "${CON:-}" | sed 's/\\n/\n/g' | grep -Ev 'appLaunch with non-empty page stack' | grep -Ei '\[error\]|\[warn\]|fail' || true)
ck "console 无页面运行时 error（已剔 devtools 导航噪音）" "${CON_PAGE:-（空）}" '^（空）$'

echo
if [ "$FAIL" -eq 0 ]; then
  echo "✅ flashback-journey E2E 全绿：$PASS 项断言通过（截图在 $ART/）"
else
  echo "❌ $FAIL 项失败（$PASS 项通过）"
fi
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
