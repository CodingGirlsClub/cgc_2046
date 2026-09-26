# 闪念间 web 端 user journey 与功能梳理（闪念间 · 金句墙 · 许愿树）

> 日期：2026-09-26 ｜ 代码基线：`feat/flashback-overnight` @ `c58d6e5a` ｜ 范围：web 端（`web/`）的闪念间、金句墙、许愿树，并与微信小程序对照
> 证据写作 `文件:行号`；标「（推断）」的是读代码推出来、没有实际运行验证的结论。

## 一、结论先行

- **第一次来的人，web 端是完整的**：访客能逛公开首页、金句墙、许愿树；拿着邀请链接的人能走完首程（开场 → 答题 → 显影 → 写今天 → 寄出 → 收好）。
- **有一个要马上修的崩溃**：在时间长廊里点开自己的私密愿望，页面会因为取数缺字段而报错（H0）。
- **其余问题集中在「回来的人」和「已登录的人」**：
  1. 绑定了档案的人，web 上没有任何常驻入口能回到自己的时间长廊；文案却一直写「从『我的』进入」，而 web 没有「我的」（H1）。
  2. 已登录的人在首程点「收好」，仍要填手机号、收短信验证码（每次都花短信费）；填了别的号码，还会被悄悄切到另一个账号（H2）。
  3. 许愿树的「附议 · 我能出力」「接收提醒」在 web 上只有文字，没有能点的东西（H3、M2）。
  4. 小程序已有的「已登录一键收好 / 找回」「寄出后调雾」「完整的金句授权管理」「我的愿望」「取消附议」，web 都没有（第五节）。
- **建议先做第七节的 P0 六件事**：一个崩溃修复，加五个改动小、影响大的入口与文案问题；其中「已登录一键收好」同时省掉短信费。

## 二、页面与入口

| 路由 | 页面 | 给谁 | 登录要求 |
|---|---|---|---|
| `/flashback` | 公开首页：统计、随机 3 句金句、点赞、找回表单 | 所有人 | 否（可被搜索引擎收录） |
| `/flashback/enter?token=` | 首程 | 持邀请 / 找回邮件链接的人 | 否，需有效链接 |
| `/flashback/capsule` | 时间长廊（胶囊） | 持链接的人、已绑定档案的登录用户 | 链接或已绑定账号 |
| `/flashback/event/[key]` | 场次相册 | 持链接的人、所有登录用户（#933） | 未登录且无链接 → 跳登录（带回跳） |
| `/flashback/[publicSlug]` | 实名支持档案页 | 所有人 | 否 |
| `/flashback/voices` | 金句墙 | 所有人 | 否 |
| `/flashback/wishes` | 许愿树 | 所有人 | 否（写愿望要登录或链接） |

全站导航（`web/components/site-header.tsx:66-71`）有「闪念间」「金句墙」「许愿树」三个一级入口，分别指向 `/flashback`、`/flashback/voices`、`/flashback/wishes`；登录后多出的「我的报名」「我的学习」（`site-header.tsx:58-61`）都不指向闪念间。`/flashback` 首页不感知登录态：登录与否、有没有档案，看到的都是同一个公开首页。

## 三、功能 × 用户状态

✓ 能用 ｜ ✗ 不能用 ｜ — 不适用

| 功能 | 访客 | 持链接（未登录） | 已登录 · 无档案 | 已登录 · 有档案 |
|---|---|---|---|---|
| **闪念间** | | | | |
| 公开首页（统计、随机金句、点赞） | ✓ | ✓ | ✓ | ✓（与访客相同） |
| 首程（开场 → 寄出） | — | ✓ | —（需要链接） | —（已寄出直达长廊） |
| 收好（绑定账号） | — | ✓ 手机号 + 短信验证码 | ✓ 同左，仍要短信 | — |
| 时间长廊 | ✗ | ✓ | ✗（提示去找回） | ✓，但**没有入口**，只能靠书签 |
| 编辑今天 / 补寄 / 撤下 | — | ✓ | — | ✓ |
| 寄出后调「当年答案」的雾 | — | ✗（文案引导去小程序） | — | ✗ |
| 卡片导出（PNG / 系统分享 / Markdown） | — | ✓ | — | ✓ |
| 回访时管理金句授权 | — | 只能单向打开匿名档 | — | ✗（要求 token，绑定后不显示） |
| 删除档案 | — | ✓ | — | ✓ |
| 场次相册 | ✗（跳登录） | ✓ | ✓ 只读，未寄出者只显示姓氏 | ✓ |
| 找回（邮箱） | ✓ | ✓ | ✓（结果不和当前账号挂钩） | — |
| 换手机号 | — | ✗（文案说去小程序） | — | ✗ |
| **金句墙** | | | | |
| 浏览（按城市）、点赞、分享、实名页 | ✓ | ✓ | ✓ | ✓ |
| 举报 | ✗（后端也没有接口） | ✗ | ✗ | ✗ |
| **许愿树** | | | | |
| 浏览（城市钉、换一批、筛选）、期待、举报、分享 | ✓ | ✓ | ✓ | ✓ |
| 写愿望 | ✗（跳登录） | ✓（仅长廊里） | ✗（提示去绑定档案） | ✓ |
| 看「我的愿望」（含待审、私密） | ✗ | 仅长廊里，点开私密愿望会崩（H0） | ✗ | 同左 |
| 附议 · 我能出力 | ✗（只有「去小程序」两行字） | ✗（长廊旧版里能点，但必报错） | ✗ | 仅长廊旧版，只能 +1 |
| 取消附议 | ✗ | ✗ | ✗ | ✗ |
| 留言 | ✗ | 仅长廊旧版 | ✗ | 仅长廊旧版 |
| 接收提醒 | ✗（只有一句文字承诺） | ✗ | ✗ | ✗ |

## 四、旅程

### 4.1 访客

1. 导航「闪念间」→ `/flashback`：并发拉 `FlashbackPublicStats` + `FlashbackRandomQuotes`（`web/components/flashback/public-home.tsx:54-68`）；没有数据时显示叙事文案，不显示裸 0。
2. 点场次 → `/flashback/event/[key]` → 未登录跳 `/login?next=…`，登录后回到这一场。
3. 点金句的实名署名 → `/flashback/[publicSlug]`；点「看全墙 →」→ 金句墙。
4. 首页底部找回：填邮箱 → `FlashbackRecover` → 「请查收邮箱」（同形，不透露有没有档案）→ 邮件里的链接进 4.2。
5. 金句墙 `/flashback/voices`：首次播四幕开场（可跳过；系统开了「减少动态效果」则直接跳过）→ `FlashbackPublicQuotes`（不带城市，取热门 60 条）→ 按城市浏览（在这 60 条里筛）、点赞（`FlashbackLikeQuote`，设备键去重、乐观更新失败回滚）、分享单句 `?item=` 链接。
6. 许愿树 `/flashback/wishes`：`FlashbackCities` + `FlashbackPublicWishes`（固定 60 条）→ 城市钉 / 换一批 / 「全部 · 已有回响」筛选 → 期待（`FlashbackExpectWish`）、举报（`FlashbackReportWish`）、分享；「写下我的愿望」→ 登录页；「我能出力」→ 两行「去小程序」说明。

### 4.2 持链接的人（邀请或找回邮件）

1. `/flashback/enter?token=` → token 存进 sessionStorage、从地址栏清掉（`web/components/flashback/journey.tsx:106-116`）→ `FlashbackEnter`。
2. 链接失效分三种：已被收进账号 / 已失效 / 找不到 → 失效页；「已被收进账号」给登录链接，但**不带回跳**（M5）。
3. 回访：已寄出 → 直达长廊；有未寄出的草稿 → 直达写背面。
4. 首次：开场（记忆线快门 / 圆梦线拆信）→ 散照 + 答题（多场时）→ 显影（`FlashbackMarkRevealed`）→ 翻面写今天（今天状态、想要 / 能给、动员、订阅、金句授权级别）。
5. 寄出前逐句选雾 / 亮 → `FlashbackAdjustFog` → `FlashbackAdjustTodayFog` → `FlashbackSubmitToday` → `FlashbackSetQuoteLicense` → `FlashbackSendToWall`；任一步失败停下并可重试（`web/components/flashback/send-register.tsx:109-154`）。
6. 寄出后「收好」：`RequestPhoneCode`（发一条短信）→ `FlashbackRegisterBind(token, phone, code)` → 进长廊；可以跳过，之后只能凭链接回来。

### 4.3 已登录 · 没有档案

1. 导航里没有「我的档案 / 长廊」；手动打开 `/flashback/capsule` → 提示「去自助找回」→ 回 `/flashback`（不带 `#recover` 锚点，L4）。
2. 相册：`/flashback/event/[key]` 只读看全场（#933），返回按钮回首页。
3. 找回：首页填邮箱 → 找回邮件 → 链接 → 走 4.2 的首程 → 「收好」时再填手机号 + 短信验证码。填的号码如果不是当前账号的号码，档案会绑到那个号码的账号，并把当前登录切过去（`backend/lib/cgc_2046/flashback/tokens.ex:580-594`：按号码 find-or-create 账号并换会话）。
4. 许愿树写愿望 → `flashback_person_not_bound` → 提示「去绑定闪念间档案」，链到 `/flashback#recover`。

### 4.4 已登录 · 有档案

1. 没有常驻入口，只能靠书签或浏览器历史进 `/flashback/capsule`（H1）。
2. 长廊：城市钉筛选（`FlashbackCapsule(city)`）→ 时间走廊（点城市堆进相册）+ 今天格 + 未来场次 + 许愿帧（旧版）。
3. 今天格：编辑今天（`FlashbackSubmitToday` + `FlashbackAdjustTodayFog`，已寄出的幂等补寄）、撤下（二次确认 → `FlashbackRetract`）。
4. 卡片导出：摘要 / 全文 → PNG 下载、系统分享、Markdown；「金句分享」勾选只在持 token 时出现（M1）。
5. 删除档案：`FlashbackDeletePreview` → 输入 `DELETE` → `FlashbackDelete`。
6. 许愿（长廊旧版 `WishFrames`）：写 / 删自己的公开愿望、留言（`FlashbackAddWishComment`）、附议（`FlashbackEndorseWish`，只传 wishId）；点开私密愿望会崩（H0）。

## 五、和小程序的差距

### 5.1 小程序有、web 没有

| 功能 | 后端字段 | 小程序 | web 现状 |
|---|---|---|---|
| 已登录一键收好 / 自动认领 | `flashbackClaim` | 登录后自动匹配、带链接一键收好 | 没有；已登录也走手机号 + 短信（H2） |
| 找回并绑到当前账号 | `flashbackRecoverVerifyForAccount`、`flashbackRecoverClaimForAccount` | 找回面板（邮箱 + 贴链接） | 没有（M3） |
| 回访时调「当年答案」的雾 | `flashbackAdjustFog` | 回访随时可调 | 只在首程寄出前（M4） |
| 回访时完整管理金句授权 | `flashbackSetQuoteLicense` | 三档切换、关闭、多选句子 | 只能单向打开匿名档，且要有 token（M1） |
| 卡片公开链接开关 + 朋友视角公开卡 | `flashbackSetCardSharing`、`flashbackSharedCard` | 有开关、有公开卡页 | 都没有（M12） |
| 「我的愿望」页 | `flashbackMyWishes` | 状态、额度、删除 | 没有；无档案的人看不到自己的愿望，待审的也看不到（M11） |
| 我能出力（出力类型 + 留言 + 提醒） | `flashbackEndorseWish`（含 `contributionTypes` / `message` / `notify`） | 完整表单 | 公开树只有文字引导；长廊旧版只能 +1（H3） |
| 取消附议 | `flashbackCancelEndorseWish` | ✓ | 文档写了没用（L3） |
| 回响提醒订阅 | 附议的 `notify` + 订阅授权 | ✓ | 只有一句提示文字（M2） |
| 城市全集、服务端按城市筛选 | `flashbackVoiceCities`、`flashbackWishCities`、列表的 `city` 参数 | ✓ | 前端静态表 / 在已加载数据里筛（M10） |
| 「已有回响」按真实回响筛选 | `flashbackPublicWishes(withEchoes)` | 服务端筛选 | 按附议数近似（M8） |
| 许愿树分页 | `flashbackPublicWishes(offset)` | 每页 24 条 | 固定 60 条，只能换一批（L7） |

### 5.2 web 有、小程序没有

圆梦线 CTA（`flashbackDreamTarget`）、寄出时手机号注册绑定（`flashbackRegisterBind`，小程序用微信登录代替）、实名支持档案页（`flashbackPublicProfile`）、愿望举报界面（小程序接口已接好但没有界面）。

### 5.3 两端都没用的后端字段

- `flashbackDeleteWishComment`、`flashbackUpdateContact`：web 写了文档但没有调用。
- `flashbackRedeem`：没有任何提交端；web 后台有兑换处理队列，但会一直是空的。
- `flashbackAdminSetQuoteHidden`：金句下线开关，没有任何后台界面。

## 六、缺口清单

严重度：**高** = 核心旅程走不通、会报错崩溃、或有花钱 / 串号风险；**中** = 承诺了但没有、或功能缺失；**低** = 体验打磨。

### 高

- **H0 点开自己的私密愿望，页面崩溃**
  - 证据：长廊的私密愿望卡点开后进 `WishModal`（`web/components/flashback/wish-frames.tsx:139-146`），弹窗直接 `wish.comments.map(...)`（`wish-frames.tsx:506`）；但胶囊查询的 `myPrivateWishes` 没取 `comments` 和 `mine`（`web/lib/graphql/flashback.ts:848-856`）→ `undefined.map` 报错（推断：代码路径直接，未实际运行）。即使不崩，缺 `mine` 也不会出删除按钮，私密愿望删不掉。测试的构造数据带了这两个字段，所以没测出来。
  - 建议：查询补上 `comments` 与 `mine`（或弹窗对缺字段兜底），并补一条用真实查询形状构造数据的测试。
- **H1 绑定档案的人回不到自己的时间长廊**
  - 证据：登录态导航只有「我的报名」「我的学习」（`web/components/site-header.tsx:58-61`）；`/flashback` 首页不感知登录态；全站指向 `/flashback/capsule` 的只有首程完成、找回完成、相册返回三处（`journey.tsx:137,182`、`recover-form.tsx:82`、`event-detail.tsx:109,129`）。文案却写「从今往后从『我的』进入」（`web/messages/zh-CN.json:2726,2875`，以及 `:103,2981`），web 没有「我的」。
  - 建议：登录态导航加「我的闪念间」→ `/flashback/capsule`；`/flashback` 首页对已绑定用户显示「进入我的时间长廊」；文案改成 web 上真实存在的入口。
- **H2 已登录用户「收好」仍要短信，还可能串号**
  - 证据：`send-register.tsx` 不读登录态，一律走手机号 + 验证码（`journey.tsx:92,293`）；后端 `register_bind` 按填的号码 find-or-create 账号并换会话（`tokens.ex:580-594`）。小程序已登录时走 `flashbackClaim(token)` 一键收好、不发短信，web 没有接这个接口。
  - 建议：已登录时改用 `flashbackClaim(token)` 一键收好到当前账号（与小程序一致，省短信费、不串号）；未登录才走手机号。和「收好遇到别人账号的档案要不要报错」一起定（第八节问题 3）。
- **H3 许愿树「附议 · 我能出力」在 web 上是死路**
  - 证据：公开树点「我能出力」只弹两行文字「附议与出力在小程序里完成…」（`web/app/[locale]/flashback/wishes/wishes-wall.tsx:560-563`，`zh-CN.json:3080-3081`），没有小程序码、没有跳转，桌面用户无路可走。长廊旧版 `WishFrames` 虽然真的调用 `FlashbackEndorseWish`（`wish-frames.tsx:112,172`），但该接口要求登录（`backend/lib/cgc_2046_web/graphql_schema.ex:1847` 起），只持链接未登录的人点了必报错，而报错文案是「进入时间长廊需要你的专属链接，或登录已绑定的账号」（`zh-CN.json:113`）——用户此时就在长廊里，文案答非所问。出力类型、留言、通知意愿三个参数 web 从未传过。
  - 建议：先定产品口径（第八节问题 1）。无论哪种，最少要做：「去小程序」弹层给小程序码；长廊旧版的附议按钮对未登录的人换成正确提示。

### 中

- **M1 回访时的金句授权管理残缺**：导出卡上的「金句分享」勾选要求有 token 才显示（`card-export.tsx:46`），且只能单向打开匿名档；后端 `flashbackSetQuoteLicense` 的 token 本来就是可选的（`graphql_schema.ex:1686`），同文件其他写操作也都支持「token 或登录」两种身份。绑定后 token 作废，这个勾选就永远消失——既看不到已授权状态，也没法补授权或关闭。
- **M2 「接收提醒」只有一句文字**：`wishes-wall.tsx:464-466` 显示「有新进展时，可选择接收提醒。」（`zh-CN.json:3121`），旁边没有任何开关或订阅入口。要么接入提醒通道，要么删掉这句。
- **M3 已登录找回没有 web 版**：`web/lib/graphql/flashback.ts` 里没有 `flashbackRecoverVerifyForAccount` / `flashbackRecoverClaimForAccount`。H2 做完后（找回链接 → 首程 → 已登录一键收好），这条自然被覆盖。
- **M4 寄出后不能再调「当年答案」的雾**：只有寄出前的确认步骤能调（`journey.tsx:259-262`）；长廊只能调「今天」的雾（`today-actions.tsx:159-166`）。文案承认要去小程序（`zh-CN.json:2848`「寄出之后，还能在小程序里继续调整」）。
- **M5 失效链接「已被收进账号」→ 登录不带回跳**：`invalid-token.tsx:28` 是裸 `/login`；相册页同类跳转带了 `next`（`event-detail.tsx:101`）。叠加 H1，登录后用户彻底找不到自己的卡。
- **M6 换手机号没有 web 入口**：`FLASHBACK_UPDATE_CONTACT` 已定义但全站没有调用（`web/lib/graphql/flashback.ts:633-643`）；文案直说「Web 端目前没有更新入口」（`zh-CN.json:2833`）。小程序也没有这个入口（5.3）。
- **M7 许愿树留言只在长廊旧版有**：公开树页（`wishes-wall.tsx`）不引用留言接口，只逛树、不进长廊的人永远用不到留言。
- **M8 「已有回响」筛选名不副实**：实际按附议数过滤（`wishes-wall.tsx:207` `endorsementCount > 0`），后端专门的 `withEchoes` 参数（`graphql_schema.ex:441`）没用上。
- **M9 首页没有许愿树板块**：`public-home.tsx` 有金句墙板块和「看全墙 →」，没有许愿树；只看首页的人发现不了许愿树（导航里有一级入口）。
- **M10 金句墙按城市看不全**：地图城市来自前端写死的 45 城表（`web/app/[locale]/flashback/voices/cities.ts:8-53`），列表只取热门 60 条、在其中按城市筛（`voices-wall.tsx:288-295` 不传城市）。后端的 `flashbackVoiceCities`（全量，`graphql_schema.ex:502-505`）和列表的城市参数都没用上：不在表里的城市在地图上选不中，冷门城市的金句按城市看不到。
- **M11 web 没有「我的愿望」**：`flashbackMyWishes` 没有接；没有档案的人看不到自己写过的愿望，待审的也看不到。
- **M12 web 没有卡片公开链接与朋友视角公开卡**：`flashbackSetCardSharing` / `flashbackSharedCard` 只在小程序用，web 无开关、无路由。

### 低

- **L1** 写愿望的登录回跳写死 `/flashback/wishes`，丢掉当前城市 / 单条（`wishes-wall.tsx:360`）。
- **L2** 公开树的写愿望弹窗不显示今年剩余名额（`wishes-wall.tsx:615` 传 `null`），要撞到上限才知道；长廊入口传的是真实值（`corridor.tsx:77`）。
- **L3** 附议后无法取消：`FLASHBACK_CANCEL_ENDORSE_WISH` 全站零调用（`flashback.ts:1149-1156`）。
- **L4** 「去找回」出口不一致：今天格带 `#recover` 锚点（`today-slot.tsx:55`），长廊无档案态、相册返回不带（`capsule-view.tsx:138`）。
- **L5** 实名页把网络错误和「不存在 / 未授权」混成同一个 404，也没有重试（`profile-view.tsx:18-23`）；许愿树已经区分了这两种（`wishes-page.tsx`）。
- **L6** 相册页在渲染过程中直接 `router.replace` 跳登录（`event-detail.tsx:99-103`），应放进 effect，避免严格模式下重复跳转。
- **L7** 公开树只能「换一批」，不能翻页看完整棵树（`FlashbackPublicWishes` 从不传 `offset`）；小程序每页 24 条可翻页。
- **L8** 金句墙没有举报入口；后端也没有对应接口，属产品能力不对称，不是前端漏做。

> 说明：找回表单里的手机号验证码分支（`recover-form.tsx` 的 `phase === "code"`）是 2026-09-26 刻意保留、默认关闭的代码（手机号找回暂停），不算缺口。

## 七、建议的补齐顺序

**P0（尽快）**

1. H0：修私密愿望崩溃（补查询字段 + 测试）。
2. H1：登录态导航与首页加「我的闪念间」入口，文案改成真实入口。
3. H2：已登录一键收好（省短信费、不串号），同时覆盖 M3。
4. M5：失效链接的登录带回跳。
5. M2：删掉「接收提醒」这句空头承诺（或换成真实能力说明）。
6. M1：金句授权勾选对已绑定用户也显示，并支持关闭。

**P1（补功能）**：M4 寄出后调雾、M6 换手机号、M7 公开树留言、M8 回响筛选改用 `withEchoes`、M9 首页许愿树板块、M10 城市改用 `flashbackVoiceCities` 与服务端筛选、M11 我的愿望、L1、L2、L7。

**P2（需要先定产品口径）**：H3 附议在 web 怎么做、M12 卡片公开链接、L3 取消附议、L8 金句举报。

## 八、需要拍板的问题

1. **附议 · 我能出力**：web 直接开放（登录即可，进展用邮件通知）？还是保持「去小程序」，但给小程序码？
2. **提醒**：web 要不要做提醒（邮件）？不做就删掉文案。
3. **web 已登录「收好」改一键收好（不再发短信）**：同意吗？遇到已属于别的账号的档案，是否统一「报错、不悄悄挪」（与 #932、邮箱找回一致）？
4. **换手机号、寄出后调雾、卡片公开链接**：web 补齐，还是继续引导到小程序？

## 附录：范围外的顺带发现

- **web 后台「单人重发」调不通**：后台闪念间页调用 `resendFlashbackOutreach`（`web/app/[locale]/admin/flashback/page.tsx:268`），以 mutation 发送 `flashbackAdminResendOutreach`（`web/lib/graphql/admin.ts:1336-1339`）；但后端把这个字段定义在 Query 块里（`backend/lib/cgc_2046_web/graphql_schema.ex:292`，Query 块起于第 35 行），按 GraphQL 规则会被拒绝。另外「重发」有副作用，本就应放在 Mutation 块——建议后端挪到 Mutation，前端不用改。
- **兑换没有提交端**：`flashbackRedeem` 两端都没调用，后台兑换队列会一直是空的（5.3）。
- **小程序抖音 / 小红书端的回访页 `pages/flashback` 端内没有入口**：只能从深链或分享进入，与其注释里写的「从『我的』进入」不一致（非 web 范围，仅记录）。
