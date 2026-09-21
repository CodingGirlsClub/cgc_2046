---
title: "feat: 金句墙 Voices 独立公开页（生产第一批）"
date: 2026-09-21
type: feat
topic: flashback-voices-wishes
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: docs/plans/2026-09-21-1550-requirements-flashback-voices-wishes-plan.md
execution: code
---

# feat: 金句墙 Voices 独立公开页（生产第一批）

## Goal Capsule

- **目标**：把已验收的「山河渐醒」原型落成生产版金句墙独立公开页——陌生人无需登录即可读、赞、分享单句与整墙，并被自然引导找回档案。
- **手段**：后端新建 QUOTE 单句模型（R37）并改造公开查询与点赞；Web 端移植原型视觉到 `/flashback/voices`，接上真实数据与入口三件套。
- **依据**：需求计划 R10–R14、R26–R29、R35、R37；原型实施计划（U1 用户评审已通过，2026-09-21）。
- **非目标**：许愿树生产化、Echo、小程序端实现、通知系统（见 Scope Boundaries）。

## Summary

后端：`flashback_quotes` 新表（稳定 UUID、span 引用、快照、hidden_at），从 `quote_license.chosen_quote_spans` 迁移；点赞从按人归集改为按句；公开查询按句输出涌现序 top 60 + 随机入口。
前端：原型 `river-dawn`（在 `codex/voices-wishes-web-prototype` 分支）移植为生产页 `/flashback/voices`，接 GraphQL 真实数据；header 加入口、落地页改随机导流、分享卡落地页接续金句墙、赞后轻提示、实名档链档案页。

## Problem Frame

金句墙数据与点赞已在生产运行（落地页 quotes 段），但：单句没有独立身份（无法单句分享/单句点赞/单句撤回）；金句墙没有自己的页面和入口（埋在落地页第三屏）；分享卡看完即止（GAP-2 回流断点）。原型已验证体验，本批把数据模型与页面补齐。

## Requirements Trace

| 需求 | 实施单元 |
|---|---|
| R37 单句身份与生命周期 | U1、U2、U4 |
| R10–R11 读与匿名赞 | U2、U3 |
| R12 单句/整墙分享 | U4 |
| R13–R14 选城/浏览/找回 | U3、U6 |
| R26 入口三件套（Web 部分） | U5 |
| R27 赞后转化轻提示 | U6 |
| R28 实名档链档案页 | U2、U3 |
| R29 点赞防刷（去重+频控） | U2 |
| R33 分享卡回流接续 | U7 |
| R35 涌现序 + 随便听听 | U2、U3 |
| R5–R9 开场与入口旅程 | U3、U4 |
| R22–R24 双端与减少动态效果 | U3 |

## Key Technical Decisions

- **KTD1 · QUOTE 独立表，span 引用不复制文本。** Governs R37。（session-settled: user-directed）`flashback_quotes`：`id / quote_license_id / answer_id / span(jsonb) / city / year / hidden_at / inserted_at / updated_at`。文本渲染时从 `answer.raw_text` 按 span 切片；授权撤回（license.hidden_at）级联隐藏。编辑圈选 = 原地改 span，id 不变，链接与点赞保留。
- **KTD2 · 点赞迁移：旧数据归到该授权者第一句。** Governs R37。`flashback_likes` 加 `quote_id`，旧行按「该 person 的第一段 span 对应的 quote」回填（与现状展示口径一致），新唯一索引 `(quote_id, voter_key)`；`person_id` 列随迁移完成后删除（不保留兼容路径）。
- **KTD3 · 原型移植而非搬运。** 原型是 throwaway（无测试、无错误处理、仅中文硬编码）；生产页复用其视觉与交互结构，但重写为生产组件：接 GraphQL、加载/失败/空态、i18n 走 `web/messages/*.json`、减少动态效果分支保留。素材（`china-geo.json` / `rivers.json` / `terrain.png`）从原型目录复制进生产目录。
- **KTD4 · 分享链接复用页面路由。** 单句链接 = `/flashback/voices?item=<quote_id>`（带 item 抑制开场，直达该句）；整墙链接 = `/flashback/voices`。不引入新 slug 体系。
- **KTD5 · 发布纪律。** 一律 merge commit 的 PR → develop；GraphQL 契约变更（`flashbackLikeQuote` 入参 personId→quoteId）属破坏性变更，先查小程序端是否消费这两个字段（执行时确认：预期仅 web 落地页消费），若有消费则按 #752 组合发布纪律同窗口处理。
- **KTD6 · 地图合规为发布前置。** DataV GeoAtlas 数据（含 `100000_JD` 南海诸岛）与 Natural Earth 数据的使用条件、`terrain.png` AI 生成素材政策，合并前完成核对；核对不通过则替换素材，不带着风险上线。

## Implementation Units

### U1. QUOTE 数据模型与迁移

- **Goal**：单句金句成为有稳定身份的一等实体。
- **Requirements**：R37
- **Dependencies**：无
- **Files**：`backend/lib/cgc_2046/flashback/quote.ex`（新建）、`backend/lib/cgc_2046/flashback/quote_license.ex`（关联）、`backend/lib/cgc_2046/flashback/like.ex`（re-key）、`backend/priv/repo/migrations/`（新迁移）、`backend/test/cgc_2046/flashback/`（对应测试）
- **Approach**：
  1. 新建 `Quote` Ash 资源（字段见 KTD1），`belongs_to :quote_license` / `belongs_to :answer`；`hidden_at` 可逆。
  2. 迁移：遍历现有 license 的 `chosen_quote_spans`，每段生成一行 Quote（城市/年份从 person 快照）。
  3. `flashback_likes` 加 `quote_id` 并回填（KTD2），建新唯一索引，删旧 `(person_id, voter_key)` 索引与 `person_id` 列。
  4. license `hidden_at` 置位/清除时级联隐藏/恢复其 quotes。
- **Test scenarios**：
  - 迁移：3 个 license（分别 1/2/0 段 span）→ 生成 3 行 Quote，城市/年份快照正确；0 段不产生 Quote
  - 点赞回填：person 有 2 句、旧点赞 5 个 → 全部归到第一句；唯一索引拒绝同 voter 重复赞
  - license 置 hidden_at → 其 quotes 全部隐藏；清除 → 恢复
  - Quote 单句 hidden_at 不影响同 license 其他句
- **Verification**：迁移在 dev 库跑通且行数可解释；`mix test` 相关文件全绿。

### U2. 公开查询、点赞与 GraphQL 契约改造

- **Goal**：公开读面按句输出；点赞按句去重并有频控；契约层同步。
- **Requirements**：R10、R11、R28、R29、R35
- **Dependencies**：U1
- **Files**：`backend/lib/cgc_2046/flashback/public.ex`（`quotes/1` 改造）、GraphQL schema/resolver（`flashbackPublicQuotes`、`flashbackLikeQuote`）、`web/lib/graphql/flashback.ts`、`web/lib/flashback-voter.ts`（不变，仅确认复用）
- **Approach**：
  1. `quotes/1` 改为按 Quote 输出：涌现序（like_count 优先、updated_at 次之）、limit 60、过滤 hidden；返回 `quoteId`、文本切片、署名（匿名档「姓\*\* · 年 · 城」；credited 档附 `publicSlug`）、like_count、liked_by_viewer。
  2. 新增随机入口查询：全量未隐藏 Quote 中随机取 N 句（「随便听听」，N 由前端定，默认 3）。
  3. `flashbackLikeQuote` 入参 `personId` → `quoteId`；频控：同 voter_key 每分钟点赞次数上限（执行时定值，先按 30）。
  4. 执行时确认：小程序端是否消费 `flashbackPublicQuotes` / `flashbackLikeQuote`（预期否），有则按 KTD5 处理。
- **Test scenarios**：
  - 未授权/已隐藏 quote 不出现在任何公开查询
  - 涌现序：高赞句排前；同赞按更新时间
  - 匿名 voter 点赞/取消往返，计数与 liked_by_viewer 正确；重复点赞被唯一索引拒绝
  - 频控触发返回业务错误码
  - credited 档返回 publicSlug，匿名档不返回任何身份字段
  - 随机入口：返回数量正确且不包含隐藏句
- **Verification**：backend 测试全绿；GraphQL 契约测试更新通过。

### U3. 生产版金句墙页面 `/flashback/voices`

- **Goal**：把已验收原型移植为生产页面，接真实数据。
- **Requirements**：R5–R14、R22–R24、R28、R35
- **Dependencies**：U2
- **Files**：`web/app/[locale]/flashback/voices/page.tsx` 及同目录组件、`web/components/flashback/voices/`（地图、阅读区、开场）、素材文件（从原型复制）、`web/messages/zh-CN.json`、`web/messages/en.json`、对应 vitest 测试
- **Approach**：
  1. 按 KTD3 移植原型 `river-dawn`：四幕开场（可跳过/点城市中断/重播/分镜）、白昼双端布局、城市栏、阅读区、赞与分享、找回入口。
  2. 数据接 U2 的 GraphQL；加载/失败/空态（无授权句时的空墙文案）；`?item=` 直达抑制开场（KTD4）。
  3. 减少动态效果分支与 `prefers-reduced-motion` 保留；原型的 `?motion=1` 评审参数**不带入生产**。
  4. i18n：全部文案进 messages；原型硬编码中文仅作 zh-CN 源。
  5. 「随便听听」入口接 U2 随机查询，会话内不重复。
- **Execution note**：视觉以原型 evidence 截图为准做结构断言；先跑通数据链路再做动画细节。
- **Test scenarios**：
  - 空态：无授权句时显示空墙文案而非报错
  - `?item=<id>` 直达：不播开场、定位该句；item 失效（已撤回）→ 失效页（U4）
  - 点赞乐观更新失败回滚
  - 长句（3 行）与短句排版不破版（结构断言：无横向溢出）
  - 减少动态效果下直接白昼、全部内容可读
  - 沪杭等相邻城市可通过城市栏分别选中
- **Verification**：`pnpm vitest` 相关文件绿；ego-browser 双端（1440/390）结构断言 + 交互走通 + 截图；`pnpm build` 通过。

### U4. 单句分享与失效页

- **Goal**：单句链接可分享、可直达；撤回后旧链接体面失效。
- **Requirements**：R12、R37
- **Dependencies**：U3
- **Files**：`web/app/[locale]/flashback/voices/`（分享弹层与失效视图）、`web/messages/*.json`
- **Approach**：
  1. 分享弹层复制 `?item=` 链接（KTD4）；整墙分享不带 item。
  2. item 指向已撤回/不存在句 → 失效视图：「这句话已被作者收回」+「看全墙」入口，HTTP 200（软 404 语义，不报错页）。
  3. 分享事件埋点：点击分享 / 复制完成 分开记录（SHARE_EVENT 一期只做前端事件上报到既有埋点通道，若无通道则仅 console 标记 + 列入后续）。
- **Test scenarios**：
  - 有效 item 直达该句；无效/已撤回 item 显示失效视图且含看全墙入口
  - 整墙分享链接不含 item，打开播开场（首次）或直接白昼（回访）
- **Verification**：vitest + ego-browser 走通两条链接路径。

### U5. 入口三件套（Web 部分）

- **Goal**：金句墙有目录级入口与落地页导流。
- **Requirements**：R26
- **Dependencies**：U3
- **Files**：`web/components/site-header.tsx`、`web/components/flashback/public-home.tsx`、`web/messages/*.json`、对应测试
- **Approach**：
  1. header 导航加「金句墙」（与闪念间并列或并入闪念间下拉，按现有导航结构选择，执行时定）。
  2. 落地页 quotes 段改为「随机几句 + 看全墙 →」：调 U2 随机查询，非精选、非全量。
- **Test scenarios**：
  - header 出现金句墙入口且可导航
  - 落地页随机段每次加载句数正确、含看全墙链接；点赞在落地页仍可用（回归）
- **Verification**：vitest + ego-browser 导航走通。

### U6. 赞后转化轻提示

- **Goal**：首赞后出现一次不打断的找回引导。
- **Requirements**：R27、R14
- **Dependencies**：U3
- **Files**：`web/app/[locale]/flashback/voices/`（toast/轻提示组件）、`web/messages/*.json`
- **Approach**：首次点赞后显示轻提示（「这句话是当年真实的报名答案——你也写过吗？找回你的那一张 →」），可忽略、自动消失、不阻断继续阅读；每会话只出现一次（sessionStorage）。
- **Test scenarios**：
  - 首赞出现提示，再赞不重复出现；关闭后不再出现
  - 提示不遮挡赞/分享按钮（结构断言）
- **Verification**：vitest + ego-browser。

### U7. 分享卡落地页接续金句墙（GAP-2）

- **Goal**：#771 分享卡看完能继续到金句墙。
- **Requirements**：R33
- **Dependencies**：U3
- **Files**：分享卡落地页组件（执行时定位 #771 的页面文件，预期在 `web/app/[locale]/flashback/` 下）、`web/messages/*.json`
- **Approach**：卡尾加「这面墙上，还有更多当年的声音 →」模块：随机 2–3 句预览（复用 U2 随机查询）+ 看全墙入口；只导航接续，不共享授权域数据。
- **Test scenarios**：
  - 卡尾模块出现且预览句非空；点进全墙导航正确
  - 分享卡本身授权域行为不变（回归：未授权卡仍不可见）
- **Verification**：vitest + ego-browser 走通「开卡 → 进墙」。

### U8. 实名档链档案页

- **Goal**：credited 金句可跳到作者公开档案页。
- **Requirements**：R28
- **Dependencies**：U2（返回 publicSlug）、U3
- **Files**：`web/app/[locale]/flashback/voices/`（署名组件）
- **Approach**：credited 档署名渲染为链接 → `/flashback/[publicSlug]`；匿名档纯文本，无任何身份入口。
- **Test scenarios**：
  - credited 句署名可点且 href 正确；匿名句无链接
- **Verification**：vitest。

## Scope Boundaries

**本批包含**：QUOTE 模型与迁移、公开查询与点赞改造、生产版金句墙页面、单句分享与失效页、Web 入口三件套、赞后轻提示、分享卡接续、实名档链接。

**本批不包含（非目标）**：许愿树生产化、Echo 四子域、通知系统、小程序端任何实现（含发现页入口卡）、运营后台改动。

### Deferred to Follow-Up Work

- 小程序发现页入口卡与小程序金句墙页（依赖小程序渲染方案验证，见原型实施计划 §9 差距 6）
- 作者正反馈一期（R34，回访可见共鸣数）——依赖 QUOTE 落地后另立小批
- 分享回流三段漏斗的完整埋点（依赖 SHARE_EVENT 通道决策）
- 金句排序时间衰减（二期优化）

## Open Questions（执行时解决，不阻塞开工）

- 分享卡（#771）落地页的确切文件位置与现状结构（U7 开工时定位）。
- 频控阈值与「随便听听」默认句数的最终取值。
- 失效页与空墙的具体文案（走 messages 评审）。
- header 入口的最终位置（并列还是闪念间下拉）。
- 小程序端是否消费 `flashbackPublicQuotes` / `flashbackLikeQuote`（U2 开工时确认，预期否）。

## Verification Contract

- `cd backend && mix test` 全绿（含新迁移与查询测试）；`mix format --check-formatted`、编译零警告。
- `cd web && pnpm vitest` 全绿；`pnpm exec tsc --noEmit` 与 eslint 通过；`pnpm build` 通过。
- ego-browser 双端实测：开场四幕、跳过/中断/重播、分享直达、失效页、赞与轻提示、入口导航、分享卡接续。
- 授权边界专项：未授权/已撤回内容不出现在任何公开面（含旧链接）。
- 地图与素材合规核对完成（KTD6）后方可合并。

## Definition of Done

- 上述 Verification Contract 全过；
- 陌生人从分享链接进入可直接读句、赞、再分享（真实数据）；
- header 与落地页入口可达金句墙；
- 撤回一句后其旧链接显示失效页，其余句不受影响；
- PR 以 merge commit 合入 develop（4 checks 绿）。
