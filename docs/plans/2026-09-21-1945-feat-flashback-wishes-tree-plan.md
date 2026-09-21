---
title: "feat: 许愿树 Wishes 生产批（生产第二批）"
date: 2026-09-21
type: feat
topic: flashback-voices-wishes
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: docs/plans/2026-09-21-1550-requirements-flashback-voices-wishes-plan.md
execution: code
---

# feat: 许愿树 Wishes 生产批（生产第二批）

## Goal Capsule

- **目标**：把许愿树从「长廊成员面」升级为生产级公开空间——任何人可读公开愿望、零门槛 ❤️ 期待；登录用户可「附议 · 我能出力」（含回响通知订阅）；已认领校友可写愿望；全链路有机审与运营审核兜底。
- **手段**：后端扩建 WISH / ENDORSEMENT、新建 EXPECTATION 与举报模型、接入既有微信内容安全检测；Web 移植原型许愿树视图；小程序长廊扩建期待与附议表单。
- **依据**：需求计划 R15–R21、R30–R32（2026-09-21 讨论定稿）；原型实施计划 §4 J4–J7、§5 ERM；后端/前端现状只读核对（develop `5acdfb46`，2026-09-21）。
- **非目标**：Echo 回响能力（生产第三批）、小程序树页读面（渲染方案未验证）、作者正反馈、分享度量（见 Scope Boundaries）。

## Summary

后端：`flashback_wishes` 扩署名快照 / 期望地 / `hidden_at` 下架 / 信用降级；新建 `flashback_wish_expectations`（voter_key 去重，与 LIKE 同口径）；`flashback_wish_endorsements` 扩出力表单与游客身份；新建 `flashback_reports`；愿望/留言/附议留言接入既有 `content_check`；新增公开匿名查询与期待/举报 mutation；配置开关做上线门。
前端：Web 在批 1 的 `/flashback/voices` 页面骨架上生产化许愿树视图（读/期待/分享/举报/写愿望入口）；小程序长廊加 ❤️ 期待与「附议 · 我能出力」表单（复用既有订阅消息基建，新增 `flashback_wish_echo` 场景）。

## Problem Frame

愿望能力已上线但困在成员面：公开愿望只经 `flashback_capsule`（token/登录）透出，路人无处可读；「期待」模型不存在（现有附议是成员计数）；附议没有出力语义；**已上线的许愿/留言 UGC 未过内容安全检测（合规缺口，本批 U4 修复）**；公开面无举报与下架手段。原型已验证许愿树体验，本批把数据模型、审核体系与公开页面补齐。公开树页带上线门：愿望攒到不冷清再由运营开启（已拍板的上线节奏）。

## Requirements Trace

| 需求 | 实施单元 |
|---|---|
| R15 愿望展示/署名/期待状态/分享 | U1、U6、U7 |
| R16 公开/私密选择与边界 | U1、U4、U6（查询层强制过滤） |
| R17 署名预览（匿名/展示名，不暗示法定名） | U1、U8、U10 |
| R18 提交后可找到、撤回后移除 | U1、U6、U7（单愿望链接与失效页） |
| R19 期待/提醒/报名独立动作 | U2、U3、U9 |
| R21 双页切换保留城市 | U7 |
| R30 期待/附议两动作与去重 | U2、U3、U6、U9 |
| R31 附议出力表单、留言一期仅运营可见、聚合分布 | U3、U5、U6、U9 |
| R32 审核分层（机审前置、先发后审、下架、举报、频控、信用分级） | U4、U5 |
| R36 回响（仅订阅授权链路预埋；Echo 本体不在本批） | U3 |

## Key Technical Decisions

- **KTD1 · WISH 扩四字段，存量愿望不进公开树。** Governs R15–R18。`flashback_wishes` 加：`signature`（署名快照：匿名遮罩「王\*\*」或写入时 display_name 快照，与 QUOTE 快照口径一致）、`city` 改为作者可选「期望地」（默认名册城市，候选集 = 既有城市列表，不允许自由输入）、`hidden_at`（admin 下架，与作者撤回 `deleted_at` 区分）、`listed_at`（公开树授权标记）。**迁移：存量愿望 `listed_at = null`**——历史「成员可见」不等于同意全网公开（授权不扩大红线），只有新流程（明示「公开=任何人可见」）写入的愿望带 `listed_at`。公开树查询过滤 `listed_at IS NOT NULL`。
- **KTD2 · 期待独立表，附议自动计入由写入保证。** Governs R30。新建 `flashback_wish_expectations`：`(wish_id, voter_key)` 唯一，voter_key 与 LIKE 同套口径（`u:<user_id>` / `a:<device_uuid>`，复用 `web/lib/flashback-voter.ts` 与 `likes.ex` 的校验/IP 限频模式）。**附议提交时服务端同步 upsert 一条 `u:<user_id>` 期待行**——「念念不忘数 = COUNT(expectations)」天然含附议者，唯一索引保证同人不重复；附议 mutation 接受可选 `anonVoterKey`，服务端合并删除该设备的匿名期待行（登录前后不双计）。
- **KTD3 · 附议 actor 扩为登录用户，通知授权复用 notification_consents。** Governs R31。`wish_endorsements` 加 `user_id`（person_id 改可空）+ 生成列 `actor_key`（`p:<person_id>` / `u:<user_id>`），唯一约束改 `(wish_id, actor_key)`；加 `contribution_types text[]`（venue/organize/speak/sponsor/other）、`message`（≤500，一期仅运营可见）、`notify boolean`；GraphQL 暴露取消附议。通知授权**不建新表**：复用 `notification_consents` + `grantMiniProgramNotificationConsent`，新增模板键 `flashback_wish_echo`。**外部依赖：该微信订阅消息模板需提前申请**（模板未配置时按既有 fail-closed 模式，附议表单不显示通知勾选，其余流程不受影响）。注意：讨论实录提到的 `flashback_action_scheduled` 模板在代码库中不存在，通知发送链（Notifications.Service → Consent.take → Wechat.Client.send_notification + NotificationWorker 模板注册表）需按既有范式新增 flashback 条目。
- **KTD4 · 机审复用既有 content_check，覆盖全部愿望 UGC。** Governs R32。愿望创建、愿望留言、附议留言接入 `Wechat.Client.content_check/3`（`backend/lib/cgc_2046/integrations/wechat/client.ex:681-775`），语义与报名 reason 一致（`enrollment.ex:777-833`）：wechat 检查、tt/xhs 跳过、infra 故障 fail-open + telemetry、risky/review fail-closed 返回 `flashback_content_rejected`。私密愿望同样过机审但不进人工队列。**本单元修复已上线 UGC 无检测的合规缺口，可独立提前合并。**
- **KTD5 · 审核体系：举报新表 + hidden_at 下架 + 信用分级 + admin 管理面。** Governs R32。新建 `flashback_reports`（target wish/comment、reporter voter_key 或 user_id、reason、status），公开举报 mutation 带频控；`wishes.hidden_at` 复用 quote_license `set_hidden` 模式（专用 action，用户面不可写，公开读面过滤）；信用分级：被下架作者的 `wishes_review_required_at` 置位后，其新公开愿望默认 `hidden_at` 待审，admin 放行即清除；admin 闪念间看板（`web/app/[locale]/admin/flashback/page.tsx`）新增愿望管理面：新愿望队列 / 举报队列 / 附议留言（按愿望聚合）/ 一键下架与放行。频控沿用既有：年度 3 条额度（`wishes.ex:256-300`）+ GraphQL RateLimit（create_wish 30/15min 已有，举报新增 10/15min）。
- **KTD6 · 上线门用配置开关，fail-closed。** 无 feature-flag 框架，沿用「配置即开关」范式：`config :cgc_2046, :flashback_wishes, public_enabled:` env 注入，默认关。门关闭时公开查询返回未开启态，Web 树页显示「愿望正在收集中」+ 写愿望 CTA（小程序长廊成员面不受门控，维持现状）。运营确认愿望攒够后开 env 即上线，无需发版。
- **KTD7 · Web 端一期：期待 + 写愿望，不开放附议。** Governs R30–R31。已拍板「Web 游客无订阅通道，想被通知引导去小程序」；附议是承诺动作、需触达通道，故 Web 树页只有 ❤️ 期待（voter_key），「附议 · 我能出力」入口展示但引导去小程序（兼作转化）。Web 写愿望对**已登录且已认领**校友开放（web 有完整登录体系，`useAuthed` + person.user_id 判定），未登录点「写下我的愿望」走登录/找回引导。
- **KTD8 · 与批 1 的协调。** 树页复用批 1 U3 的 `/flashback/voices` 页面骨架、地图组件与开场（原型形态：同页 view 切换、保留城市、不重播开场，R21）。**U7 开工前批 1 须已合并 develop**（或从其分支切出并预期 rebase）；若批 1 页面结构不支持 view 切换，退为独立路由 `/flashback/wishes` 共享组件，切换经 query 保城市。

## Implementation Units

### U1. WISH 模型扩建与迁移

- **Goal**：愿望具备公开树所需的署名、期望地、下架与授权标记。
- **Requirements**：R15–R18
- **Dependencies**：无
- **Files**：`backend/lib/cgc_2046/flashback/wish.ex`、`backend/lib/cgc_2046/flashback/wishes.ex`、`backend/priv/repo/migrations/`（新迁移）、`backend/test/cgc_2046/flashback/wishes_test.exs`
- **Approach**：
  1. 按 KTD1 加 `signature` / `hidden_at` / `listed_at`；`city` 增加创建入参（期望地，默认名册城市，候选集校验复用 `alumni_projection.ex:205-239` 城市列表语义）。
  2. 署名：创建时作者选匿名/展示名（R17 预览文案在 U8/U10），`signature` 存快照值；匿名 = 既有 `masked_name` 口径。
  3. 迁移：存量愿望 `listed_at = null`、`signature = 遮罩姓`（现状口径不变）；新创建流程（带公开范围明示）写 `listed_at`。
  4. `list_public` 拆分：成员面（长廊/capsule）维持现口径；公开树查询新增 `listed_at + hidden_at + deleted_at + visibility` 过滤（U6 消费）。
- **Test scenarios**：
  - 迁移后存量愿望 `listed_at` 为空、不出现在公开树查询，仍出现在成员面
  - 新愿望：署名快照两种取值正确；期望地默认名册城市、可选候选城市、拒绝自由文本
  - `hidden_at` 置位 → 公开树移除、成员面保留作者本人可见；作者 `deleted_at` 撤回行为不变（回归）
  - 年度额度 3 条回归不破
- **Verification**：迁移在 dev 库跑通行数可解释；`mix test` 相关文件全绿。

### U2. 期待模型与去重不变量

- **Goal**：❤️「我也期待」成为零门槛匿名计数动作。
- **Requirements**：R19、R30
- **Dependencies**：U1
- **Files**：`backend/lib/cgc_2046/flashback/wish_expectation.ex`（新建）、`wishes.ex`（计数与期待/取消）、`backend/lib/cgc_2046/flashback.ex`（注册资源）、迁移、测试
- **Approach**：
  1. 按 KTD2 建表 `(wish_id, voter_key)` 唯一；voter_key 校验与 IP 限频复用 `likes.ex:22-24, 98-116` 模式（60 次/小时/IP）。
  2. 期待/取消对称（upsert / 删行）；计数实时 COUNT，不落冗余列（与 LIKE 一致）。
  3. 念念不忘数 = COUNT(expectations)；附议写入联动在 U3。
- **Test scenarios**：
  - 匿名 voter 期待/取消往返，计数与 expected_by_viewer 正确；重复期待被唯一索引拒绝（幂等）
  - IP 限频触发返回业务错误码
  - 私密/下架/未 listed 愿望不可被期待（不泄露存在性，复用 likes 目标校验模式）
- **Verification**：`mix test` 全绿。

### U3. 附议模型扩建与通知授权链路

- **Goal**：「附议 · 我能出力」成为含出力承诺与订阅授权的承诺动作。
- **Requirements**：R19、R30、R31、R36（仅授权链路预埋）
- **Dependencies**：U2
- **Files**：`backend/lib/cgc_2046/flashback/wish_endorsement.ex`、`wishes.ex`、迁移、`backend/lib/cgc_2046_web/graphql_schema.ex`（endorse 改造 + 取消附议）、`backend/lib/cgc_2046/notifications/notification_worker.ex`（注册 `flashback_wish_echo` 模板键，发送逻辑属 Echo 批，本批只注册键与授权余额读写）、测试
- **Approach**：
  1. 按 KTD3 扩字段与 actor_key 唯一约束；endorse mutation 入参：contribution_types、message、notify、anonVoterKey；要求登录（user_id）或成员身份（person_id）。
  2. 提交时：upsert endorsement + upsert `u:<user_id>` 期待行 + 合并删除 anonVoterKey 匿名期待（KTD2）。
  3. notify=true 且小程序已授权 → `Consent.grant` 写 `flashback_wish_echo` 余额（授权动作在 U9 小程序侧发起，经既有 `grantMiniProgramNotificationConsent`）。
  4. 取消附议：删 endorsement；联动期待行保留（期待是独立动作，R19）。
  5. 留言过机审（U4 的 content_check 接入点之一）。
- **Test scenarios**：
  - 附议后念念不忘数 +1 且同人重复附议不双计；先匿名期待后登录附议 → 合并不双计
  - contribution_types 枚举校验；message 超 500 拒绝；取消附议后期待数不变
  - 未登录游客附议被拒绝并引导登录（错误码）
  - notify 授权余额写入与模板未配置时 fail-closed
- **Verification**：`mix test` 全绿；GraphQL 契约测试更新通过。

### U4. 机审接入（合规缺口修复，可独立提前合并）

- **Goal**：愿望相关全部 UGC 过微信内容安全检测。
- **Requirements**：R32
- **Dependencies**：无（只依赖既有 content_check）
- **Files**：`backend/lib/cgc_2046/flashback/wishes.ex`（create_wish / add_comment / endorse 的 message）、错误映射（`flashback_content_rejected`）、测试
- **Approach**：按 KTD4 在三个写入点接入 `content_check`；openid 从 actor 平台身份取（无平台身份的 web 登录用户走 `:skipped` 路径并记录 telemetry——与 enrollment 一致）；拒绝时返回业务错误码，前端文案在 U8/U10。
- **Test scenarios**：
  - mock 检测通过/拒绝/故障三态：通过即发布、拒绝返回错误码、故障 fail-open 且有 telemetry
  - 私密愿望过机审但不产生任何人工队列记录
- **Verification**：`mix test` 全绿。**本单元建议作为独立 PR 提前合并**（修复已上线合规缺口）。

### U5. 审核体系：举报 + 下架 + 信用分级 + admin 管理面

- **Goal**：先发后审的后置兜底全部就位。
- **Requirements**：R32
- **Dependencies**：U1（hidden_at）、U4
- **Files**：`backend/lib/cgc_2046/flashback/report.ex`（新建）、`wishes.ex`（set_hidden / 信用降级 / 放行）、`graphql_schema.ex`（`flashbackReportWish` 公开 mutation + admin 查询/mutation）、`web/app/[locale]/admin/flashback/page.tsx` + `web/lib/admin.ts`（愿望管理面）、`web/messages/*.json`、测试
- **Approach**：
  1. `flashback_reports`：target_type(wish/comment) + target_id、reporter（voter_key 或 user_id）、reason（≤200）、status(pending/dismissed/actioned)；举报 mutation 频控 10/15min/IP。
  2. admin：`flashbackAdminSetWishHidden`（复用 quote_license set_hidden 模式）；下架时若作者累计被下架 ≥1 次 → 置 `wishes_review_required_at`；该作者新公开愿望默认 hidden 待审，admin 放行清除 hidden。
  3. admin 看板新 tab「愿望」：新愿望列表（含 listed 状态）、举报队列（pending 优先）、附议留言聚合（按愿望，含出力分布与联系方式——联系方式仅 admin 可见，来自登录用户账号）、一键下架/放行/驳回举报。
- **Test scenarios**：
  - 举报写入与频控；重复举报同目标幂等或计数（执行时定，默认允许重复但同人同目标 1 条）
  - 下架 → 公开面消失；放行 → 恢复；信用降级作者新愿望默认待审
  - admin 面非管理员访问被拒（fail-closed 回归）
- **Verification**：backend + web 测试全绿；admin 面 ego-browser 走通下架/放行。

### U6. 公开 GraphQL 契约与上线门

- **Goal**：公开匿名读面与公开写面就位，门控默认关。
- **Requirements**：R15、R16、R19、R30、R31
- **Dependencies**：U2、U3、U5
- **Files**：`backend/lib/cgc_2046/flashback/public.ex`（新增 wishes 公开查询）、`graphql_schema.ex`（`flashbackPublicWishes` / `flashbackExpectWish` / `flashbackReportWish` / endorse 改造挂载）、`config/config.exs` + `config/runtime.exs`（`flashback_wishes.public_enabled`）、`web/lib/graphql/flashback.ts`、契约测试
- **Approach**：
  1. `flashbackPublicWishes(city, item)`：过滤 `listed_at + hidden_at + deleted_at + visibility=="public"`；返回 id、内容、署名快照、城市、期待数、附议聚合（M 人附议：场地 ×a · 组织 ×b，**不返回留言与个人信息**）、expected_by_viewer（voterKey 回显）；排序默认期待数优先 + 最新次之（与涌现序对称，Open Questions 确认）；`item=<wish_id>` 单条查询供分享直达。
  2. `flashbackExpectWish`（公开，voterKey + IP 限频）、`flashbackReportWish`（公开，频控）。
  3. KTD6 门控：`public_enabled=false` 时公开查询返回空 + `collecting` 标记（页面显示收集态）；成员面（capsule）不受门控。
- **Test scenarios**：
  - 门开/关两态查询行为；私密/未 listed/已下架/已撤回愿望不出现在任何公开查询（含 item 直达）
  - 聚合分布数值正确且无留言泄露；expected_by_viewer 随 voterKey 正确
- **Verification**：backend 测试全绿；契约测试通过。

### U7. Web 许愿树公开页

- **Goal**：原型许愿树视图生产化，接真实数据。
- **Requirements**：R15–R19、R21–R24、R30
- **Dependencies**：U6；批 1 U3（页面骨架，KTD8）
- **Files**：批 1 的 `web/app/[locale]/flashback/voices/` 增加 wishes 视图（或独立路由，KTD8）、`web/components/flashback/`（愿望阅读区、期待按钮、举报入口、收集态/空态）、`web/messages/*.json`、vitest 测试
- **Approach**：
  1. 移植原型 wishes 视图：纸签地图、按城阅读区、❤️ 期待（voter_key，乐观更新失败回滚）、聚合出力分布展示、双页切换保留城市不重播开场。
  2. 单愿望分享：`?view=wishes&item=<wish_id>` 直达（抑制开场）；已撤回/下架/不存在 → 失效视图「这个愿望已被作者收回」+「看看这棵树」入口（与批 1 U4 金句失效页对称）。
  3. 举报入口（愿望卡与留言）；「附议 · 我能出力」按钮 → 引导去小程序浮层（KTD7）；「写下我的愿望」入口 → 未登录走登录/找回引导，已认领校友开 U8 表单。
  4. 收集态（门关闭）：「愿望正在收集中」+ 写愿望 CTA；空态文案；i18n 全量；减少动态效果分支沿用。
  5. 回响相关 UI（筛选/卡片）**不在本批**，页面结构预留。
- **Test scenarios**：
  - 期待/取消乐观更新与失败回滚；举报提交成功与频控提示
  - item 直达与失效页两路径；双页切换城市保留（结构断言）
  - 收集态与空态渲染；手机 390 无横向溢出、动作不被工具条遮挡
- **Verification**：`pnpm vitest` 绿；ego-browser 双端结构断言 + 交互走通 + 截图；`pnpm build` 通过。

### U8. Web 写愿望表单扩建

- **Goal**：Web 端已认领校友可写生产级愿望。
- **Requirements**：R16–R18、R32
- **Dependencies**：U7
- **Files**：`web/components/flashback/wish-frames.tsx`（`WishFormModal` :168-267 改造，复用进树页）、`web/lib/graphql/flashback.ts`（CREATE_WISH 入参扩展）、`web/messages/*.json`、测试
- **Approach**：表单加署名选择（匿名 / display_name，预览明示「将以 display_name 实名展示」，不暗示法定名，R17）+ 期望地选择（候选集）+ 公开/私密明示（公开=任何人可见）+ 机审拒绝文案（`flashback_content_rejected` →「这句话没能挂上树，换种说法试试」）；提交后镜头定位所选城市、新纸签出现（原型 J5 行为）。
- **Test scenarios**：
  - 署名两档预览与提交值正确；机审拒绝显示文案且不丢草稿
  - 私密愿望不进公开列表（提交后公开面查询不到）
  - 未认领登录用户被引导认领；额度耗尽文案（既有 `flashback_wish_quota_exceeded`）
- **Verification**：vitest + ego-browser 走通写→找到→撤回。

### U9. 小程序：期待 + 附议表单 + 订阅授权

- **Goal**：小程序长廊愿望卡具备两个生产动作。
- **Requirements**：R19、R30、R31
- **Dependencies**：U3、U6
- **Files**：`miniprogram/src/pages/flashback-corridor/index.tsx`（愿望卡与弹层 :542-590, :808-853）、`miniprogram/src/domain/subscription.ts`（新增 `flashback_wish_echo` 场景与触点）、`miniprogram/config/index.ts`（模板 env 槽）、`miniprogram/src/api/operations.ts` + `api/real.ts`（ExpectWish / EndorseWish 改造 / CancelEndorse）、`miniprogram/src/domain/flashback.ts`、`domain/error-copy.ts`、相关测试
- **Approach**：
  1. 愿望卡加 ❤️ 期待：匿名用 `a:<device>` voter_key，登录后合并（KTD2 anonVoterKey）。
  2. 「附议 · 我能出力」表单：未登录先 `wx.login` 一键登录；表单 = 接收回响通知（默认勾选 → `requestTouchpointConsent` 走既有订阅基建，模板未配置时按 fail-closed 隐藏勾选）+ 我能出力（场地/组织/讲课分享/物资/其他留言）+ 提交；已附议态与取消。
  3. 聚合分布与念念不忘数展示与 Web 一致。
- **Test scenarios**：
  - 期待/取消计数正确；附议全流程（登录 → 授权 → 提交 → 聚合更新）；取消附议
  - 模板未配置时表单无通知勾选且可正常提交；机审拒绝文案
- **Verification**：小程序测试绿；微信开发者工具编译预览走通；真机或模拟器交互验证。

### U10. 小程序：写愿望扩建

- **Goal**：小程序写愿望与 Web 同规则。
- **Requirements**：R16–R18、R32
- **Dependencies**：U4、U8（规则对齐）
- **Files**：`miniprogram/src/pages/flashback-corridor/index.tsx`（许愿 sheet :878-916）、`miniprogram/src/api/operations.ts`（CreateWish 入参扩展）、`domain/error-copy.ts`、测试
- **Approach**：许愿 sheet 加署名选择与期望地选择（与 U8 同规则同文案）；机审拒绝文案；公开范围明示文案（listed_at 授权前提）。
- **Test scenarios**：与 U8 对称（署名/机审/私密边界/额度）。
- **Verification**：小程序测试绿；开发者工具走通。

## Scope Boundaries

**本批包含**：WISH/EXPECTATION/ENDORSEMENT/REPORT 模型与迁移、机审接入、审核体系与 admin 管理面、公开 GraphQL 契约与上线门、Web 许愿树公开页与写愿望表单、小程序期待/附议/写愿望扩建。

**本批不包含（非目标）**：

- Echo 回响本体（状态机、admin 发布、通知发送触发、回响卡 UI）——生产第三批，依赖本批的订阅授权链路
- 小程序树页读面（地图渲染方案未验证，与小程序金句墙一起另立项）
- 作者正反馈（R34）、分享度量 SHARE_EVENT、金句排序时间衰减
- 写愿望资格扩大到非校友（未决项，维持已认领校友）
- 作者编辑愿望（维持撤回重发；编辑规则未决）

### Deferred to Follow-Up Work

- 历史愿望的作者回访征询（「愿意挂到公开树吗？」）——授权不扩大红线下的存量激活，另立小批
- 金句/档案公开面的举报入口（本批举报表按 target_type 通用设计，UI 只接愿望）
- 附议留言公开化（需审核能力具备后，R31）
- 小程序发现页入口卡与分享卡片物料（R26 小程序部分）
- 期待/附议的登录身份与匿名设备合并的完整规则（本批为 best-effort 合并，KTD2）

## Open Questions（执行时解决，不阻塞开工）

- 公开树默认排序：建议期待数优先 + 最新次之（与金句涌现序对称）——开工前与用户确认。
- 期望地候选集：建议复用既有城市列表（名册 ∪ 场次 ∪ 公开愿望城市），不允许自由输入——确认。
- 展示名变更不回溯旧愿望（署名快照，与 QUOTE 一致）——确认。
- 上线门开启时机与「不冷清」的运营口径（建议 admin 目测手动开，不设自动阈值）——确认。
- 举报同人同目标是否幂等；频控最终阈值。
- Web 树页路由形态（view 切换 vs 独立路由）随批 1 结构定（KTD8）。
- `flashback_wish_echo` 模板文案与申请排期（外部依赖，Echo 批前必须就位）。

## Verification Contract

- `cd backend && mix test` 全绿（含迁移、期待/附议/举报/机审/门控）；`mix format --check-formatted`、编译零警告。
- `cd web && pnpm vitest` 全绿；`tsc --noEmit` 与 eslint 通过；`pnpm build` 通过。
- `cd miniprogram && pnpm test` 全绿；微信开发者工具编译预览通过。
- ego-browser 双端实测：树页读/期待/举报/写愿望/失效页/收集态；admin 下架与放行。
- 授权边界专项：私密、未 listed、已下架、已撤回愿望不出现在任何公开查询与页面（含旧链接）；附议留言不出现在任何公开响应。
- 合规专项：愿望/留言/附议留言三态机审（通过/拒绝/故障）行为正确。

## Definition of Done

- 上述 Verification Contract 全过；
- 路人在 Web 树页可读公开愿望、❤️ 期待、举报；小程序用户可附议（含订阅授权）；
- 已认领校友在 Web 与小程序均可写愿望（署名/期望地/公开私密），机审拒绝有体面文案；
- admin 可看板巡检、一键下架、放行；信用降级作者先审后发；
- 上线门默认关，开 env 即公开面生效；
- PR 以 merge commit 合入 develop（4 checks 绿）；U4 建议独立 PR 提前合。
