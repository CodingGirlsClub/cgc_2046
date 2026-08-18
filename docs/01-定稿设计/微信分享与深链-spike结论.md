# 微信分享与深链 spike 结论

> 计划：advisor-plans/011-share-url-scheme-spike.md（design/spike，非全量实现）
> 日期：2026-08-18
> 状态：调查完成 + 原型验证 + 决策清单已拍板（D1-D5 全 A，2026-08-18 plan owner）
> 结论来源约定：每条结论标注「SDK 源码 file:line」或「微信官方文档 URL」；官方查不到明文的标 **未核实——上线前必须确认**；禁止编造数字。

---

## 1. 分享卡片契约

### 1.1 聊天转发（onShareAppMessage / Taro useShareAppMessage）

| 字段 | 契约 | 来源 |
|---|---|---|
| title | 转发标题，默认当前小程序名称。官方无字数上限明文；社区惯例约 40 字节（约 30 汉字），超出截断。**未核实——上线前必须确认**（官方 Page.html 未写数字，惯例来自第三方总结） | 官方 https://developers.weixin.qq.com/miniprogram/dev/reference/api/Page.html#onShareAppMessage-Object-object ；惯例来源第三方（有赞/腾讯云文章） |
| path | 转发路径，必须以 `/` 开头的完整页面路径，默认当前页面 path。event-detail 契约：`/pages/event-detail/index?id=${id}&kind=${kind}`（**必须带 kind**——`getContent(kind, id)` 按 kind 分流 getEvent/getCourse，见 `miniprogram/src/api/real.ts:135-149`） | 官方 Page.html |
| imageUrl | 自定义图片：本地文件路径 / 代码包文件路径 / 网络图片路径；支持 PNG 及 JPG；**显示图片长宽比 5:4**；默认截图（页面顶部 80% 屏宽，`share.html`）。event-detail 用现有详情图或默认截图即可（plan Out of scope：不建朋友圈素材后台） | 官方 Page.html + https://developers.weixin.qq.com/miniprogram/dev/framework/open-ability/share.html |
| promise | 可选；若存在则以 resolve 结果为准，3 秒不 resolve 回落默认参数（基础库 2.12.0+） | 官方 Page.html |
| 触发条件 | **只有定义了 onShareAppMessage，右上角菜单才显示「转发」按钮**；页面内可用 `button open-type="share"` 触发 | 官方 Page.html + share.html |
| Taro 4.2.1 支持 | `useShareAppMessage(callback)` 类型存在：`miniprogram/node_modules/@tarojs/taro/types/api/taro.hooks.d.ts:45`；返回值对象 `ShareAppMessageReturnObject`（title/path/imageUrl）：`taro.lifecycle.d.ts:85-98` | SDK 类型（Taro 4.2.1） |

### 1.2 朋友圈（onShareTimeline / Taro useShareTimeline）

- **需要单独挂载** `useShareTimeline`（Taro 4.2.1 类型存在：`taro.hooks.d.ts:63`），与 onShareAppMessage 是两个独立入口。
- 前提条件：页面需**先设置允许「发送给朋友」（onShareAppMessage）**，再设置 onShareTimeline；二者都定义后右上角才出现「分享到朋友圈」。官方原文见分享到朋友圈页。
- 基础库 2.11.3+，Android / iOS（微信 8.0.24+）。
- **不支持自定义 path**——朋友圈分享只能分享当前页面（用户从朋友圈点开的是「单页模式」页面，再点「前往小程序」进入完整小程序）。
- 单页模式限制（对 event-detail 有实质影响）：**无登录态（wx.login 不可用）、不允许跳转其它页面（含 navigateTo 小程序内跳转）、本地存储与普通模式不共用**；场景值 1154。event-detail 含报名 CTA（`register` → navigateTo），单页模式下这些交互会被禁用并 toast「请前往小程序使用完整服务」。官方禁用能力列表见分享到朋友圈页。
- 结论：朋友圈分享适合纯内容展示页；event-detail 是内容 + CTA 混合页，**v1 是否启用朋友圈需拍板**（见 §6 决策清单）。

来源：https://developers.weixin.qq.com/miniprogram/dev/framework/open-ability/share-timeline.html

### 1.3 裁剪端（tt / xhs）等价分享 API

- **抖音（tt）**：抖音小程序有原生分享能力（`tt.shareAppMessage` 类 API，需页面开启分享配置），但 **Taro 4.2.1 `@tarojs/plugin-platform-tt` dist 中未发现 onShareAppMessage / shareAppMessage 映射**（grep 零命中）——Taro 对 tt 分享 hook 的映射支持状态 **未核实——上线前必须确认**（需真机或 Taro 文档确认；若缺失则裁剪端需直调 `tt` API，违背「裁剪端只采用各自平台原生挂载」的 D03 原则时同样可接受，因为是原生而非伪统一）。
- **小红书（xhs）**：Taro `@tarojs/plugin-platform-xhs` dist 只处理 `onShareChat` / `onCopyUrl`（小红书原生分享菜单，`runtime.js:107-117`），**没有微信式「聊天卡片分享」等价物**；官方对 xhs 卡片分享的公开文档覆盖有限。结论：**裁剪端无低成本聊天卡片分享**，v1 建议不做。
- **朋友圈**：微信独有能力，tt / xhs 无等价 API。

## 2. URL Scheme 配额模型

### 2.1 开放范围（硬门槛）

- **仅针对国内非个人主体的小程序开放**。官方原文（generateScheme 页 + 获取 URL Scheme 页）。错误码 40002「暂无生成权限（个人主体小程序无权限…）」佐证。
- 本仓 `docs/合规上架/ICP备案材料清单.md` 显示主体为非个人（交叉线索）。**以官方后台实际权限为准——上线前必须确认**（plan 原文亦强调）。

### 2.2 配额与频率限制（官方数字）

| 限制 | 官方数字 | 来源 |
|---|---|---|
| 生成端每日上限 | 每天生成 URL Scheme（加密+明文）+ URL Link 总量 **50 万**（两页一致） | https://developers.weixin.qq.com/miniprogram/dev/server/API/qrcode-link/url-scheme/api_generatescheme + 总览页 |
| 打开端每日上限 | 总览页写 **600 万**/天；api_generatescheme 页写 **300 万**/天。**官方两页不一致**，总览页较新——**未核实——上线前必须确认**（以官方后台实测 / 最新公告为准） | 两处官方页 |
| 单秒频率 | **100 次/秒**（错误码 44990「reach max api second frequence limit…超过100次/秒」） | api_generatescheme 错误码表 |
| 单人限制 | **2023-12-19 起取消「一人一链」限制，支持同一条链接被多名用户访问**（官方公告）→ **同一 event 复用同一 scheme 在配额模型上可行** | api_generatescheme 注意事项 + 官方公告《URL Scheme 和 URL Link优化公告》 |

### 2.3 有效期（关键核实结果）

- **临时（到期失效）scheme 最长有效期 = 30 天**（官方请求参数表「最长有效期为30天」+ 错误码 85401「time limit between 1min and 30days」）。
- **SDK moduledoc 写「最长有效期为1年」是过时/错误的**：`backend/deps/wechat/lib/wechat/mini_program/url_scheme.ex` 的 `@type expire_time` 注释。SDK 透传不校验，**调用方必须保证 expires_at 距今 ≤30 天**；「min(活动结束 + 缓冲, 30 天)」策略见 §6 D1，在实现计划落地（spike 原型不实现 clamp）。
- 永久 scheme：**上限 10 万条 / 小程序，不可自行删除**（超限只能官方渠道处理）。来源：微信开放社区官方回复帖（https://developers.weixin.qq.com/community/develop/doc/000aaed8250b304dd4ab77c3056400 等）。

### 2.4 is_expire / expire_type / expire_interval 语义与 SDK 覆盖

| 参数 | 语义 | 是否 SDK 暴露 |
|---|---|---|
| `is_expire` | true = 到期失效；不传 = 永久 | SDK 按 `expire_time` 是否为整数自动设 `is_expire: true`（`url_scheme.ex:35-40`） |
| `expire_time` | 失效时间（Unix 秒），最长 30 天，is_expire=true 且 expire_type=0 时必填 | **SDK 暴露**（`create_scheme(client, jump_wxa, expire_time)` 第三参） |
| `expire_type` | 默认 0（失效时间）；1（失效间隔天数） | **SDK 未暴露**（写死走 expire_time 路径） |
| `expire_interval` | 失效间隔天数，最长 30 天，expire_type=1 时必填 | **SDK 未暴露** |

- **结论：SDK 覆盖够用**。业务用「活动结束时间 + 缓冲」→ Unix 秒 → `expire_time`，即 `is_expire=true + expire_type=0`（默认值）路径，SDK 完全覆盖。仅当需要「固定间隔天数」语义时才需绕过 SDK 直调 `/wxa/generatescheme`——当前需求不需要，不记录为缺口。

### 2.5 query / path 参数约束（SDK 与官方差异）

- 官方 `jump_wxa.query`：**最大 1024 字符**，只支持数字、大小写英文及部分特殊字符 `!#$&'()*+,/:;=?@-._~%`。
- SDK typedoc 写「最大 128 字符」——**过时**（`url_scheme.ex` `@type query` 注释），SDK 透传不校验，业务侧按官方 1024 为准。
- `jump_wxa.path`：**必须是已经发布的小程序存在的页面，不可携带 query**（官方）。
- 结论：spike 原型 query=`id=...&kind=...`（远小于 1024）合规。

### 2.6 其它（落地形态）

- **Android 不支持直接识别 URL Scheme**，用户无法通过 scheme 直接打开小程序，需 **H5 页面中转**再跳 scheme（官方总览页原文）。→ 短信/邮件渠道在 Android 上的落地需要中转 H5（plan Out of scope 只提供 link，此结论记入决策清单风险）。
- 加密 scheme 打开场景值 = **1065**（明文 scheme = 1286；拼接 `cq` 自定义参数后仍为 1065）。
- `env_version` 默认 release，只能生成已发布页面的 scheme。

## 3. scene / query 双轨：冷启动与热启动差异

### 3.1 官方语义

| 场景 | 进参路径 | 说明 |
|---|---|---|
| 冷启动（首次打开 / 被销毁后打开） | `App.onLaunch` 参数 / `wx.getLaunchOptionsSync()`（含 `query` + `scene`） | 参数只在启动时写入；`getLaunchOptionsSync` 始终返回**最初冷启动**的参数，**不会更新**为热启动值 |
| 热启动（小程序已在后台，再被 link 唤起） | **只触发 `App.onShow` / `wx.onAppShow`**，回调参数携带最新 `query` + `scene` | 官方 App.html：onShow「小程序启动，或从后台进入前台显示时触发」，参数与 `wx.onAppShow` 一致 |

来源：https://developers.weixin.qq.com/miniprogram/dev/reference/api/App.html（onLaunch/onShow 参数说明）

### 3.2 本仓现状与缺口（F05 复现判断）

- 现有深链链路：扫码 → `miniprogram/src/app.tsx:7-12` `useLaunch` 解析 `query.scene` → 存 `pendingScene` → navigateTo join 页（一次性消费 admitMember）。
- **`app.tsx` 只挂 `useLaunch`（冷启动）**；Taro 4.2.1 无 `useAppShow` hook（`taro.hooks.d.ts` 仅有 useLaunch / useDidShow / useShareAppMessage / useShareTimeline），App 级热启动需 `Taro.onAppShow`（运行时 API）或页面级 `useDidShow`。
- **结论：F05「前台恢复」缺口在本场景确实复发**——用户已打开小程序，再从短信/邮件点 scheme 链接，热启动进参只在 `onShow` 回调里，现有 `useLaunch` 链路收不到。
- **业务影响评估（重要）**：scheme 深链目标是 **event-detail 内容页**（query=`id`），而非 join/admit 一次性凭据。热启动漏处理的影响是「用户没被带到对应活动详情页」，不涉及凭据丢失/安全；且 event-detail 是用户可通过「发现」Tab 自然到达的公开内容页。因此 v1 可接受冷启动覆盖（app.tsx useLaunch），热启动补齐（Taro.onAppShow）列为实现计划的可选增强项。
- **双轨结论**：scheme 的 `jump_wxa.query` 与小程序码 `scene` 是**两套独立入口**——现有 scene 链路消费的是 Workspace 邀请（admit 语义），活动分享深链是 event-detail + enroll（报名语义），**不能复用 join 消费逻辑**（plan 原文，已核实 app.tsx/join/index.tsx 现状）。

## 4. 裁剪端红线边界

### 4.1 零导流门禁的覆盖边界

- 门禁实现：`miniprogram/scripts/check-no-diversion.mjs` + `diversion-policy.mjs`（CI `check:diversion`，fail-closed）。
- 扫描对象：**只扫 `dist/tt`、`dist/xhs` 编译产物的文本文件**（.js/.sjs/.json/.ttml/.ttss/.xhsml/.css/.txt），匹配 `BANNED_TERMS = ["微信", "WeChat", "OpenClacky", "加我", "二维码", "口令"]`（`diversion-policy.mjs:12`），含转义解码（\uXXXX 等两轮）。
- **门禁边界结论**：
  1. **编译进产物的静态字符串会被扫到**。event-detail 是**多端共享源码**（`app.config.ts` 的 cutPages 含 `pages/event-detail/index`，tt/xhs 都编译此页）→ **分享 title 若在源码里硬编码含「微信」等字样，会进 tt/xhs 产物、被门禁拦截**（fail-closed，exit 1）。
  2. **运行时来自服务端的分享 title 不进产物 → 门禁扫不到**。分享 title 的合规责任在服务端字段：服务端下发的 title 若含平台字样，门禁无法覆盖。
- **结论**：spike 原型分享 title 用 `item.title`（服务端数据），源码不硬编码任何平台字样 → 门禁天然零命中；如需对服务端字段也上合规护栏，需服务端侧校验（可列为实现计划增强项，本计划不实现）。

### 4.2 裁剪端分享实现边界（D03 原则）

- D03 原文：「裁剪端只采用各自平台原生挂载」——**不抽象伪统一跨端分享 API**。
- tt / xhs 原生分享现状见 §1.3：tt 原生有分享能力但 Taro 映射待核实；xhs 仅有 onShareChat/onCopyUrl，无聊天卡片等价物。
- **本 spike 结论：v1 分享只做 weapp（`useShareAppMessage`），裁剪端不做**（实现计划如需裁剪端分享，各自平台原生挂载、单独评估）。

## 5. 安全

- **scheme / 分享 path 只携带公开内容标识**：`id`（活动/课程 UUID）+ `kind`（event/course）。不含 token、邀请凭据、手机号、openid 等任何敏感值。
- 对照 join/admit 一次性凭据设计：`miniprogram_codes.scene`（一次性，`Code` 资源 `valid_scene?` + 消费后失效，join 页 `takePendingScene` 初始化即删除）——**该凭据不进分享 path，也不进 scheme query**。两条链路凭据隔离。
- 风险面评估：活动详情（title/description/schemaFields）本就是**公开内容**（event-detail 页对未登录用户可见，页面内仅报名 CTA 需登录），`id` 可枚举不新增信息泄露面；报名动作服务端有鉴权与准入策略（enrollmentPolicy：open/request/invite_only），分享带来的流量不会绕过。
- SDK 请求层红线（plan 008 已定）：请求/响应 body 不进 debug 日志（`wechat_client.ex` WechatRequester Logger `debug: false`）——scheme 生成无敏感 body，沿用即可。

---

## 6. 决策清单（已拍板）

> 每项一条：默认策略 + 拍板结果。**带 👑 的为 product owner 拍板项（≥2 条）。**

### D1 👑 默认到期策略
- **选项**：
  - A（推荐）：**到期失效**——`expire_time = min(活动结束时间 + 缓冲, 30 天)`。理由：官方临时 scheme 最长 30 天；活动有自然生命周期，结束后链接失效避免长期占用配额。
  - B：**永久 scheme**——只适合长期入口（如品牌落地页），但永久 scheme 上限 10 万不可删，活动类用永久浪费配额。
- 拍板：**已拍板 A（2026-08-18，plan owner）**。推翻成本指引：若需长期入口改 B——永久 scheme 上限 10 万不可删，活动类占用后无法回收。

### D2 👑 同 event 是否复用 scheme
- **选项**：
  - A（推荐）：**同一 event 复用同一 scheme**，存储按 `Cgc2046.Miniprogram.Code` 的现成模式（同 event/platform 保留一份有效记录，`code.ex` 的 `unique_invitation_platform` upsert 先例）。理由：2023-12-19 起取消一人一链，多用户可共享同链接；生成端 50 万/日、100 次/秒配额在复用下几乎零消耗；复用需解决「scheme 过期后如何刷新」——按 D1 到期时间重生成即可。
  - B：每次触发都新生成——高频场景（每次发短信/邮件都生成）会逼近配额且无收益。
- 拍板：**已拍板 A（2026-08-18，plan owner）**。推翻成本指引：若需每次独立链接（渠道归因）改 B——高频生成逼近生成端 50 万/日、100 次/秒配额。
- 注：存储实现（DB 字段 vs cache）在**实现计划**里定，本 spike 不做存储（plan 原文）。

### D3 👑 朋友圈分享是否进 v1
- **选项**：
  - A：**不进 v1**。理由：朋友圈分享是单页模式，event-detail 的报名 CTA 在单页模式被禁用（无登录态、不能跳转），用户必须「前往小程序」才能报名，转化路径长；且朋友圈分享能力明确适合纯内容页。v1 先做聊天卡片（onShareAppMessage）打通主链路。
  - B：进 v1——接受单页模式限制，朋友圈曝光 > 转化率优先。
- 拍板：**已拍板 A（2026-08-18，plan owner，v1 范围项，实现计划启动时产品可推翻）**。推翻成本指引：若改 B——朋友圈单页模式适配（无登录态/禁跳转的报名 CTA 降级）+ U6 真机验证。

### D4 👑 裁剪端（tt/xhs）是否进 v1
- **选项**：
  - A（推荐）：**不进 v1**。tt 的 Taro 分享映射待核实、xhs 无聊天卡片等价物（只有 onShareChat/onCopyUrl 原生菜单），成本高收益低；D03 要求各自平台原生挂载，需单独设计。v1 weapp-only。
  - B：tt 跟进（需先核实 Taro 映射 / 直调 tt API）。
- 拍板：**已拍板 A（2026-08-18，plan owner，v1 范围项，实现计划启动时产品可推翻）**。推翻成本指引：若改 B（tt 跟进）——先核实 Taro tt 分享 hook 映射（U5）或直调 tt API，各自平台原生挂载（D03）。

### D5 👑 GraphQL 面形态（v1 范围项）
- **选项**：
  - A（推荐）：**不做 GraphQL mutation 面**——scheme 由后端内部触发（如报名成功 / 短信邮件发送时生成 link），不需要 owner 手动调用。先例：现有 `generateMiniProgramCode` mutation 是 owner 手动触发的管理面，与「活动分享深链由渠道自动带出」场景不同。
  - B：暴露 mutation（如 `generateEventShareLink(eventId)`），供未来管理后台或运营手动取链接。
- 拍板：**已拍板 A（2026-08-18，plan owner，v1 范围项，实现计划启动时产品可推翻）**。推翻成本指引：若改 B——加 mutation + 权限 + rate limit（graphql_schema.ex:649 先例）。

> 拍板结果（2026-08-18，plan owner）：**D1-D5 全选 A**。D1/D2 为技术策略拍板（生效）；D3/D4/D5 为 v1 范围拍板——实现计划启动时产品可推翻，推翻时按对应 B 项成本评估。**未核实——上线前必须确认项**见下节。

## 7. 未核实清单（上线前必须确认）

| # | 项 | 影响 | 确认途径 |
|---|---|---|---|
| U1 | title 截断上限（官方无明文数字，社区惯例约 40 字节） | 分享卡片 title 截断观感 | 真机分享实测 |
| U2 | 打开端每日上限：600 万（总览页） vs 300 万（api_generatescheme 页） | 大促短信轰炸场景的触顶风险 | 官方后台 API 额度查询 / 最新公告 |
| U3 | 永久 scheme 10 万上限（官方社区回复，非正式文档页） | 若选 D1-B 永久策略的容量 | 官方后台实测 |
| U4 | 本小程序主体在官方后台的 URL Scheme 实际权限（ICP 清单显示非个人，但以官方后台为准） | **D 级阻断项**：若主体被官方判定无权限，scheme 全链路不可用 | 官方后台 / 线上凭证实测（可先用现有 appid 调一次 generatescheme） |
| U5 | Taro 4.2.1 对 tt 分享 hook 的映射（plugin-platform-tt dist 未见） | 裁剪端若进 v1（D4-B）的实现路径 | Taro 文档 / 抖音开发者工具实测 |
| U6 | 朋友圈分享真机表现（单页模式对 event-detail 布局的影响） | D3 若选 B 的适配工作量 | 真机验证 |

## 8. 真机核实记录（体例同 REAL_DEVICE_CHECKLIST.md）

| 场景 | 步骤 | 预期 | 结果 |
|---|---|---|---|
| **U4（D 级阻断）官方后台 scheme 权限** | 用现有 appid 调一次 generatescheme（或官方后台查权限） | 确认本主体可生成 scheme | **上线前必查**（若判无权限，scheme 全链路不可用） |
| 聊天卡片分享 | event-detail 右上角转发 → 生成卡片 | title/path 正确，点击进入对应详情 | 待真机（原型合入后补录） |
| scheme 冷启动 | 短信链接（iOS）→ 小程序 | 冷启动进 event-detail 详情页 | 待真机（需线上正式版，scheme 只能生成已发布页面） |
| scheme 热启动 | 已打开小程序 → 点链接 | 现状：不跳详情（F05 缺口，见 §3.2） | 待真机记录缺口复现 |
| 朋友圈单页模式 | 朋友圈点卡片 → 单页模式 | 内容可读、报名按钮「请前往小程序」toast | 待真机（若 D3 选 A 可不验） |

---

*本文档是后续实现计划的输入；实现计划引用 §6 决策清单拍板结果，不绕过重新调查。event-detail 分享 path 与 `paymentLandingUrl`（plan 006）同属「页面路径契约」，改 `app.config.ts` 页面名时两处都要看。*
