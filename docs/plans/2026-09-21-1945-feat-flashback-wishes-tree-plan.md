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

## 修订记录（2026-09-22 v2）

基线与结论更新：批 1 金句墙已合 develop（#807 `3baa15be`、#808 `a1f680bc` 失效页修复，基线 `65024478`），KTD8 前置解除、路由形态定案。计划经多视角评审 + 独立跨模型复核（结论 NEEDS_CHANGES），本版处理全部 P1/P2：

- **P1a 公开授权服务端契约**（KTD1/U1/U10）：旧客户端 `visibility=public` 不升级为全网公开，新参数 `publicListingConsent` 为 `listed_at` 唯一写入条件。
- **P1b 非校友附议可达性**（KTD7/U9）：小程序长廊对登录 viewer 开放 listed 公开愿望段 + `wishId` 深链 + 登录回跳。
- **P1c 机审身份链**（KTD4/U4）：openid 三段解析（登录 actor → person.user_id 回落 → skipped+telemetry）；U4 收窄为现有入口独立提前合并。
- **P2 附议身份统一**（KTD3）：新附议一律登录（user_id），存量 person-only 行保留并经 actor_key 计入、绑定归并升级。
- **P2 订阅余额单源**（KTD3/U3/U9）：余额只由 `requestTouchpointConsent → grantMiniProgramNotificationConsent` 上报增加；endorse 后端不 grant，`notify` 仅存意愿。
- **P2 目标资格矩阵**（KTD9）：期待/附议按访问面与身份统一判定，成员面与公开面闭合。
- **P2 分态提交反馈**（U8/U10）：私密/门关/待审/公开四态各自 feedback，附本人查看与撤回入口。
- **P2 联系方式告知**（KTD5/U9）：admin 展示登录账号 phone/email 仅限运营对接，附议表单明示告知。
- 失效文案统一「这个愿望目前无法查看」；期待乐观更新禁止整组快照回滚（#806 F2 修法纳入）；地图审图号继承为上线前运营确认项。

### v3 追加（2026-09-22 用户对齐拍板后落笔；随 v3 首次推送）

- **排序算法落地**（新 KTD10，用户拍板：现在就搞算法、要随机性）：公开树不做「期待数优先+最新次之」平铺，改用带种子的加权随机洗牌；U6 与验收同步。
- **期待/附议双指标分离**（KTD2 重写，用户拍板）：期待数 = `COUNT(expectations)`、附议数 = `COUNT(endorsements)` 各自独立，同一人两列各算一次可接受；v2 的 UNION 去重计数、取消附议补写期待行全部移除。
- **附议登录身份升级**（KTD3）用户确认通过；**公开/私密默认公开 + 加粗明示**确认。
- **私密文案说真话**（用户指出）：私密愿望对平台 MCP 治理面本就可见（`admin_list_wishes.ex:38-55`），不再写「只有自己知道」，表单与反馈文案改为「仅自己可见；平台做内容安全审核时会查看」（U8/U10）。
- 一致性修正：限频双窗（voter_key 30 次/分钟 + IP 60 次/小时）与开场记忆 localStorage 对齐批 1 实际实现（`likes.ex:10-12,122-146` / `voices-wall.tsx:34`）；U9/U10 挂 #790 mock 写面缺口依赖。

## Goal Capsule

- **目标**：把许愿树从「长廊成员面」升级为生产级公开空间——任何人可读公开愿望、零门槛 ❤️ 期待；登录用户（含无档案的非校友）可「附议 · 我能出力」（含回响通知订阅）；已认领校友可写愿望；全链路有机审与运营审核兜底。
- **手段**：后端扩建 WISH / ENDORSEMENT、新建 EXPECTATION 与举报模型、接入既有微信内容安全检测；Web 独立路由生产化许愿树视图；小程序长廊开放登录 viewer 读面、扩建期待与附议表单。
- **依据**：需求计划 R15–R21、R30–R32（2026-09-21 讨论定稿）；原型实施计划 §4 J4–J7、§5 ERM；后端/前端现状只读核对（develop `65024478`，2026-09-22，含批 1 #807/#808）；2026-09-22 评审修订与用户对齐拍板（见修订记录）。
- **非目标**：Echo 回响能力（生产第三批）、小程序树页地图读面（渲染方案未验证）、作者正反馈、分享度量（见 Scope Boundaries）。

## Summary

后端：`flashback_wishes` 扩署名快照 / 期望地 / `hidden_at` 下架 / `listed_at` 公开授权 / 信用降级；新建 `flashback_wish_expectations`（voter_key 去重，与 LIKE 同口径）；`flashback_wish_endorsements` 扩出力表单与登录用户身份（actor_key 生成列）；新建 `flashback_reports`；愿望/留言接入既有 `content_check`（openid 三段解析），附议留言随建随接；新增公开匿名查询与期待/举报 mutation；配置开关做上线门。期待数/附议数双指标分离（KTD2）；公开树排序为带种子的加权随机洗牌（KTD10）。
前端：Web 独立路由 `/flashback/wishes` 共享批 1 地图/开场/城市钉条组件（读/期待/换一批/分享/举报/写愿望入口）；小程序长廊对登录 viewer 开放 listed 公开愿望段，加 ❤️ 期待与「附议 · 我能出力」表单（复用既有订阅消息基建，新增 `flashback_wish_echo` 场景，余额单源上报）。

## Problem Frame

愿望能力已上线但困在成员面：公开愿望只经 `flashback_capsule`（token/登录且可解析 person）透出，路人无处可读、登录非校友（viewer）进长廊被 member 门禁挡住看不到愿望段；「期待」模型不存在（现有附议是 person 匿名点击计数，无用户身份、无出力语义、贴上去撕不下来）；**已上线的许愿/留言 UGC 未过内容安全检测（合规缺口，本批 U4 修复）**；公开面无举报与下架手段。原型已验证许愿树体验，本批把数据模型、审核体系与公开页面补齐。公开树页带上线门：愿望攒到不冷清再由运营开启（已拍板的上线节奏）。

## Requirements Trace

| 需求 | 实施单元 |
|---|---|
| R15 愿望展示/署名/期待状态/分享 | U1、U6、U7 |
| R16 公开/私密选择与边界 | U1、U4、U6（查询层强制过滤）、U10 |
| R17 署名预览（匿名/展示名，不暗示法定名） | U1、U8、U10 |
| R18 提交后可找到、撤回后移除 | U1、U6、U7、U8、U10（分态反馈与本人入口） |
| R19 期待/提醒/报名独立动作 | U2、U3、U9 |
| R21 双页切换保留城市 | U7 |
| R30 期待/附议两动作与去重 | U2、U3、U6、U9 |
| R31 附议出力表单、留言一期仅运营可见、聚合分布 | U3、U5、U6、U9 |
| R32 审核分层（机审前置、先发后审、下架、举报、频控、信用分级） | U4、U5 |
| R36 回响（仅订阅授权链路预埋；Echo 本体不在本批） | U3、U9 |

## Key Technical Decisions

- **KTD1 · WISH 扩四字段，存量愿望不进公开树，公开授权有服务端契约。** Governs R15–R18。`flashback_wishes` 加：`signature`（署名快照，见下）、`city` 改为作者可选「期望地」（默认名册城市，候选集 = 既有城市列表，不允许自由输入）、`hidden_at`（admin 下架，与作者撤回 `deleted_at` 区分）、`listed_at`（公开树授权标记）。**署名快照是本批新规则，不援引 QUOTE**：QUOTE 只快照 city/year，人名是渲染时从 `flashback_people` 实时生成遮蔽（`public.ex:324-325,399-408`）；WISH `signature` 在创建时按作者选择定型（匿名遮罩「王\*\*」 或 display_name），之后不回溯（display_name 改名不影响旧愿望，默认规则，Open Questions 确认）。
  **公开授权服务端契约**：`createWish` 入参加 `publicListingConsent: Boolean`（默认 false）；`listed_at` 仅当 `visibility=public AND publicListingConsent=true` 时写入。**旧客户端（无此参数）传 `visibility=public` → `listed_at=null`，维持现状「成员可见」语义，宽容不硬拒**——历史「成员可见」不等于同意全网公开（授权不扩大红线），也不给升级窗口期的存量客户端制造故障（参照 #752 组合发布纪律，本契约天然无发布窗口：后端可先合，小程序/ Web 客户端各自带参数上线即生效）。公开树查询过滤 `listed_at IS NOT NULL`。
- **KTD2 · 期待独立表；期待数与附议数双指标分离（2026-09-22 用户拍板）。** Governs R30。新建 `flashback_wish_expectations`：`(wish_id, voter_key)` 唯一，voter_key 复用 LIKE 白名单口径（`u:<user_id>` / `a:<device_uuid>`，`likes.ex:22-25,67-87`；**限频双窗复用 `likes.ex` 已实现的模式（`likes.ex:10-12, 122-146`）：voter_key 30 次/分钟 + IP 60 次/小时**，批 1 点赞实际落地规格，R29 防刷单设备高频）。**expect/unexpect 的服务端 key 判定：登录 actor → 强制 `u:<user_id>`；匿名 → 入参 `a:` 设备键**（Web 复用 `web/lib/flashback-voter.ts`，小程序新增 storage 设备键生成）。登录 expect 接受可选 `anonVoterKey`，服务端删除该匿名期待行（同一计数器内、同设备匿名期期待的合并，防同人双计）。
  **双指标分离**：❤️ 期待数 = `COUNT(expectations)`；附议数 = `COUNT(endorsements)`——附议不算期待、取消期待不动附议、取消附议不动期待，无跨表不变量需要维护；同一个人在两个计数里各出现一次是可接受的（用户拍板：分开统计没关系）。展示上两者并列：纸签 ❤️ N 人期待，阅读区 M 人附议 + 出力聚合分布（U6 契约）。`expected_by_viewer` 只看 expectations（登录查 `u:` + 设备 `a:`）；`endorsed_by_viewer` 只看 endorsements。
- **KTD3 · 附议身份统一为登录用户；通知授权余额单源；存量归并。** Governs R31。`wish_endorsements` 加 `user_id` + 生成列 `actor_key`（`u:<user_id>` / `p:<person_id>`），唯一约束 `(wish_id, actor_key)`；加 `contribution_types text[]`（venue/organize/speak/sponsor/other）、`message`（≤500，一期仅运营可见）、`notify boolean`；新增取消附议 mutation。
  **新附议一律要求登录（user_id）**（2026-09-22 用户确认）：现 endorse 的 token/person 匿名腿下线——登录即手机号快捷登录建完整账号（`signInWithPlatform`，`miniprogram/sign_in_preparation.ex:58-74`），token-only 用户在附议表单处走登录引导（claim 顺带完成，身份自然升级）。成员面旧「点一下计数」轻动作由 ❤️ 期待承接（R30 两动作本义）。`person_id` 保留为可空关联：服务端按 user 认领关系反查填充；**归并规则：endorse 前若该 user 认领的 person 对同 wish 已有存量 `p:` 附议行，旧行升级为 `u:`（填 user_id 与表单字段），不新增行、不双计**。
  **通知授权单源**：余额只由小程序 `requestTouchpointConsent` 的既有上报链（`deps.grant → grantMiniProgramNotificationConsent → Consent.grant`，`subscription.ts:410-425`、`consent.ex:6-36`）增加；endorse 后端**不调** `Consent.grant`，`notify` 仅保存通知意愿（Echo 批发送时校验 `notify AND Consent.take`）。不建新授权表，新增模板键 `flashback_wish_echo`。**外部依赖：该微信订阅消息模板需提前申请**（模板未配置时按既有 fail-closed 模式，附议表单不显示通知勾选，其余流程不受影响；`grantMiniProgramNotificationConsent` 要求登录，与附议登录前提一致）。注意：讨论实录提到的 `flashback_action_scheduled` 模板在代码库中不存在，通知发送链（Notifications.Service → Consent.take → Wechat.Client.send_notification + NotificationWorker 模板注册表）需按既有范式新增 flashback 条目。
- **KTD4 · 机审复用既有 content_check；openid 三段解析；token-only 长尾诚实收口。** Governs R32。愿望创建、愿望留言接入 `Wechat.Client.content_check/3`（`wechat/client.ex:681-775`），语义与报名 reason 一致（`enrollment.ex:777-833`）：wechat 检查、tt/xhs 跳过、infra 故障 fail-open + telemetry、risky/review fail-closed 返回 `flashback_content_rejected`。私密愿望同样过机审但不进人工队列。
  **openid 解析链（微信 msg_sec_check v2 必带 openid，token 链路无 openid 字段）**：① 登录 actor → `user_identities` 取 wechat uid（enrollment 先例 `:798-809`）；② token/成员腿 → `person.user_id` 非空时经其 user_identities 取（已认领用户全覆盖）；③ 拿不到（未认领 token-only 长尾）→ `:skipped` + telemetry 监控，与「无平台身份」先例一致，由先发后审（举报 + 巡检，KTD5）兜底。**本批不声称覆盖该长尾**，收口路线（token 入口登录化评估）列 Deferred。附议留言检测随 U3 字段落地同步接入（不属 U4 提前合并范围）。**现有入口的接入（U4）修复已上线 UGC 无检测的合规缺口，可独立提前合并。**
- **KTD5 · 审核体系：举报新表 + hidden_at 下架 + 信用分级 + admin 管理面。** Governs R32。新建 `flashback_reports`（target wish/comment、reporter voter_key 或 user_id、reason、status），公开举报 mutation 带频控；`wishes.hidden_at` 复用 quote_license `set_hidden` 模式（专用 action，用户面不可写，公开读面过滤）；信用分级：被下架作者的 `wishes_review_required_at` 置位后，其新公开愿望默认 `hidden_at` 待审，admin 放行即清除；admin 闪念间看板新增愿望管理面：新愿望队列 / 举报队列 / 附议留言（按愿望聚合）/ 一键下架与放行。**联系方式：admin 面展示附议者登录账号的 `users.phone` + `users.email`（KTD3 已保证登录前提），仅限 admin 面板、仅供运营对接出力事宜，任何公开响应不返回（U6 契约强制）；附议表单必须明示告知此用途（U9 文案）。** 频控沿用既有：年度 3 条额度 + GraphQL RateLimit（create_wish 30/15min 已有，举报新增 10/15min）。
- **KTD6 · 上线门用配置开关，fail-closed。** 无 feature-flag 框架，沿用「配置即开关」范式：`config :cgc_2046, :flashback_wishes, public_enabled:` env 注入，默认关。门关闭时公开查询返回未开启态，Web 树页显示「愿望正在收集中」+ 写愿望 CTA（小程序长廊成员面与 viewer listed 段不受门控——listed 段在门关闭期间对成员/登录用户可见，作愿望积累入口）。运营确认愿望攒够后开 env 即上线（改配置重启生效，不发版不改代码）。
- **KTD7 · Web 端一期：期待 + 写愿望，不开放附议；附议引导落小程序深链。** Governs R30–R31。已拍板「Web 游客无订阅通道，想被通知引导去小程序」；附议是承诺动作、需触达通道，故 Web 树页只有 ❤️ 期待，「附议 · 我能出力」入口展示但引导去小程序。**引导落点（P1b 修正）**：小程序长廊对登录 viewer 开放 listed 公开愿望段（U9），附议引导浮层给出小程序码/路径并携 `wishId` 深链，用户到达后定位该愿望、未登录先一键登录再回跳（`returnUrl` 范式现成，`pages/login/index.tsx:31-42`）。Web 写愿望对**已登录且已认领**校友开放（`useAuthed` + person.user_id 判定），未登录点「写下我的愿望」走登录/找回引导。
- **KTD8 · 与批 1 的协调：路由定案独立路由。** 批 1 已合并（#807/#808）。已合并的 voices 页只解析 `?item=`（金句直达），**无 view state、城市是纯组件 useState 不进 URL**（`voices-page.tsx:30-33`、`voices-wall.tsx:181`）——不具备 view 切换载体。定案：**许愿树为独立路由 `/flashback/wishes`**，与 voices 共享组件（地图、城市钉条、开场骨架、失效视图结构）；**城市经 `?city=` 入 URL**，两页互跳带 city 满足 R21「切换保留城市」；开场播放标记用 **localStorage（无过期）跨页共享**（与批 1 `flashback.voicesIntroSeen` 同机制，`voices-wall.tsx:34`；wishes 页派生 key），「双页切换不重播开场」。wish 直达 `?item=<wish_id>` 复用批 1 同型模式（network-only 校验 + direct 状态随 prop 重置——#808 修复的模式直接照用，杜绝同类白屏）。
- **KTD9 · 目标资格矩阵：期待/附议按访问面与身份统一判定。** Governs R16、R19、R30。单一愿望对动作的资格：
  - **期待（公开写）**：目标须 `listed + public + 未 hidden + 未 deleted` → 任何人（匿名 `a:` / 登录 `u:`）。成员面期待（小程序长廊内对未 listed 的成员可见愿望）走同一 mutation，服务端按「actor 能解析 person 且愿望成员可见」放行——两入口一判定函数，资格不满足统一 `flashback_wish_not_found`（不泄露存在性）。
  - **附议（承诺写）**：目标须 `public + 未 hidden + 未 deleted`；另外：`listed` 愿望 → 任何登录用户（KTD3）；未 `listed` 存量成员愿望 → 登录且可解析 person（成员语义不变）。token-only/匿名一律引导登录。
  - **举报**：公开面任何人对 listed 愿望；成员面举报入口沿用成员可见集。
  UI 按钮可用态与服务端判定一一对应（前端按已拉取数据隐藏不可行动作，服务端兜底）。
- **KTD10 · 公开树排序：带种子的加权随机洗牌（2026-09-22 用户拍板：本期即做算法，要随机性，不做平铺序）。** Governs R15、R30。采用加权无放回随机抽样（Efraimidis–Spirakis 经典算法，weighted reservoir sampling 同族）：排序键 `k_i = -ln(u_i) / w_i` 升序；权重 `w_i = (1 + 期待数 + 2 × 附议数) × freshness`，freshness = 新愿望 7 天内 ×1.5、否则 ×1；`u_i` = 由 `md5(wish.id || ':' || seed)` 派生的 (0,1] 均匀值（裁剪下界防 `ln(0)`；零新增存储，一条 SQL 完成排序 + LIMIT）。**seed 缺省 = 当日日期 + 访客 voter_key**：同访客当天内翻页稳定（offset 分页不重不漏）、跨天自然轮换；「换一批」按钮传随机 seed 立即重洗。性质：权重高者大概率靠前但非单调——热门不至于霸榜，小愿望和新愿望每天也有露脸机会；固定 seed + 固定权重 = 完全确定的顺序，单测可精确断言；构造「权重极大」用例可断言其必居首（`k → 0` 上界性质）。量纲：公开愿望百–千级，全表排序无压力。

## Implementation Units

### U1. WISH 模型扩建与迁移

- **Goal**：愿望具备公开树所需的署名、期望地、下架与授权标记，公开授权有服务端契约。
- **Requirements**：R15–R18
- **Dependencies**：无
- **Files**：`backend/lib/cgc_2046/flashback/wish.ex`、`backend/lib/cgc_2046/flashback/wishes.ex`、`backend/priv/repo/migrations/`（新迁移）、`backend/test/cgc_2046/flashback/wishes_test.exs`
- **Approach**：
  1. 按 KTD1 加 `signature` / `hidden_at` / `listed_at`；`city` 增加创建入参（期望地，默认名册城市，候选集校验复用 `alumni_projection.ex:205-239` 城市列表语义）。
  2. 署名：创建时作者选匿名/展示名（R17 预览文案在 U8/U10），`signature` 存快照值；匿名 = 既有 `masked_name` 口径。
  3. 迁移：存量愿望 `listed_at = null`、`signature = 遮罩姓`（现状口径不变）。
  4. **公开授权契约（KTD1）**：`createWish` 入参加 `publicListingConsent: Boolean`（默认 false）；`listed_at` 仅当 `visibility=public AND publicListingConsent=true` 写入；无参数的旧客户端 `visibility=public` 维持 `listed_at=null`（宽容降级，不硬拒）。
  5. `list_public` 拆分：成员面（长廊/capsule）维持现口径；公开树查询新增 `listed_at + hidden_at + deleted_at + visibility` 过滤（U6 消费）。
- **Test scenarios**：
  - 迁移后存量愿望 `listed_at` 为空、不出现在公开树查询，仍出现在成员面
  - 新愿望：署名快照两种取值正确；期望地默认名册城市、可选候选城市、拒绝自由文本
  - **授权契约：带/不带 `publicListingConsent` 的 public 请求分别 listed/不 listed；`visibility=private` 永远 null**（旧客户端行为回归）
  - `hidden_at` 置位 → 公开树移除、成员面保留作者本人可见；作者 `deleted_at` 撤回行为不变（回归）
  - 年度额度 3 条回归不破
- **Verification**：迁移在 dev 库跑通行数可解释；`mix test` 相关文件全绿。

### U2. 期待模型与计数

- **Goal**：❤️「我也期待」成为零门槛匿名计数动作，与附议双指标分离、无不变量维护负担。
- **Requirements**：R19、R30
- **Dependencies**：U1
- **Files**：`backend/lib/cgc_2046/flashback/wish_expectation.ex`（新建）、`wishes.ex`（计数与期待/取消）、`backend/lib/cgc_2046/flashback.ex`（注册资源）、迁移、测试
- **Approach**：
  1. 按 KTD2 建表 `(wish_id, voter_key)` 唯一；voter_key 校验与限频双窗复用 `likes.ex` 模式（voter_key 30 次/分钟 + IP 60 次/小时，`likes.ex:22-30, 67-87, 122-146`）。
  2. expect/unexpect 对称（upsert / 删行）；登录 actor → 服务端强制 `u:<user_id>` key，匿名 → 入参 `a:` 设备键；登录 expect 带 `anonVoterKey` 时服务端删除该匿名行（同一计数器内合并防双计）。
  3. 计数实时：期待数 = `COUNT(expectations)`，不落冗余列（与 LIKE 一致）；附议数由 endorsements 独立 COUNT（U3 就位后在 U6 契约并列返回，KTD2 双指标分离）。
  4. 目标资格按 KTD9：公开面仅 listed 目标；成员面按 person 可见性放行。
- **Test scenarios**：
  - 匿名 voter 期待/取消往返，计数与 expected_by_viewer 正确；重复期待被唯一索引拒绝（幂等）
  - 登录用户期待强制 `u:` key；带 anonVoterKey 合并删除匿名行后计数不双计
  - 双窗限频触发返回业务错误码（voter 窗与 IP 窗各一）
  - 私密/下架/未 listed（公开面）愿望不可被期待（`flashback_wish_not_found`，不泄露存在性）；成员面未 listed 愿望对成员可期待
- **Verification**：`mix test` 全绿。

### U3. 附议模型扩建与通知授权链路

- **Goal**：「附议 · 我能出力」成为含出力承诺与订阅授权意愿的登录承诺动作。
- **Requirements**：R19、R30、R31、R36（仅授权链路预埋）
- **Dependencies**：U2
- **Files**：`backend/lib/cgc_2046/flashback/wish_endorsement.ex`、`wishes.ex`、迁移、`backend/lib/cgc_2046_web/graphql_schema.ex`（endorse 改造 + 取消附议）、`backend/lib/cgc_2046/notifications/notification_worker.ex`（注册 `flashback_wish_echo` 模板键，发送逻辑属 Echo 批，本批只注册键与意愿字段读写）、测试
- **Approach**：
  1. 按 KTD3 扩字段与 `actor_key` 生成列、唯一约束；endorse mutation 入参：wish_id、contribution_types、message、notify。
  2. **身份（KTD3）**：要求登录 actor（user_id），无登录 → `flashback_auth_required` + 登录引导；`person_id` 按 user 认领反查填充（可空）；存量 `p:` 行归并升级（同 wish 已有认领 person 的 `p:` 附议 → 旧行填 user_id 与表单字段，不新增）。
  3. 计数：双指标分离（KTD2），endorse 不触 expectations、不接受 anonVoterKey；目标资格按 KTD9（listed → 任何登录用户；未 listed → 登录且成员）。
  4. **取消附议**：删 endorsement 行；期待本就独立（R19），取消附议不影响期待；返回最新附议数。
  5. **授权单源（KTD3）**：后端不调 `Consent.grant`；`notify` 仅存意愿布尔。
  6. **附议留言机审**：`message` 非空时接入 content_check（KTD4 openid 解析链，登录用户必有 wechat uid，走 ① 路径）；拒绝返回 `flashback_content_rejected`。
- **Test scenarios**：
  - 附议后附议数 +1、期待数不变（双指标分离）；同人重复附议被唯一约束幂等不双计；先匿名期待后登录附议 → 期待数 1 + 附议数 1（同一人两列各算一次，用户拍板可接受）
  - **取消期待只动期待数、取消附议只动附议数**（互不联动）；取消附议后可再次附议
  - 存量 `p:` 附议行计入附议数与出力聚合；登录归并升级不新增行不双计
  - contribution_types 枚举校验；message 超 500 拒绝；message 机审三态（通过/拒绝/故障 fail-open）
  - 未登录附议 → `flashback_auth_required`；viewer（无 person）对 listed 愿望附议成功、对未 listed 愿望 `flashback_wish_not_found`
  - **余额单源回归：endorse 全流程不触发 `Consent.grant`；notify 布尔正确持久化**；模板未配置时 fail-closed（U9 侧无勾选，后端字段容许 false）
- **Verification**：`mix test` 全绿；GraphQL 契约测试更新通过。

### U4. 机审接入现有入口（合规缺口修复，可独立提前合并）

- **Goal**：已上线的愿望创建与留言立即过微信内容安全检测。
- **Requirements**：R32
- **Dependencies**：无（只依赖既有 content_check）
- **Files**：`backend/lib/cgc_2046/flashback/wishes.ex`（create_wish / add_comment）、openid 解析辅助（登录 actor → user_identities；person.user_id 回落）、错误映射（`flashback_content_rejected`）、测试
- **Approach**：按 KTD4 在两个现有写入点接入 `content_check`；openid 三段解析（① 登录 actor ② person.user_id 回落 ③ skipped + telemetry）；拒绝返回业务错误码，前端文案在 U8/U10。**附议留言字段随 U3 落地接入，不在本单元**（避免提前合并与实施内容错位）。
- **Test scenarios**：
  - mock 检测通过/拒绝/故障三态：通过即发布、拒绝返回错误码、故障 fail-open 且有 telemetry
  - 登录用户 openid 走 ①；token 腿已认领 person 走 ②；**未认领 token-only → skipped 且有 telemetry（记录 long-tail 量）**
  - 私密愿望过机审但不产生任何人工队列记录
- **Verification**：`mix test` 全绿。**本单元作为独立 PR 提前合并**（修复已上线合规缺口）。

### U5. 审核体系：举报 + 下架 + 信用分级 + admin 管理面

- **Goal**：先发后审的后置兜底全部就位。
- **Requirements**：R32
- **Dependencies**：U1（hidden_at）、U4
- **Files**：`backend/lib/cgc_2046/flashback/report.ex`（新建）、`wishes.ex`（set_hidden / 信用降级 / 放行）、`graphql_schema.ex`（`flashbackReportWish` 公开 mutation + admin 查询/mutation）、`web/app/[locale]/admin/flashback/page.tsx` + `web/lib/admin.ts`（愿望管理面）、`web/messages/*.json`、测试
- **Approach**：
  1. `flashback_reports`：target_type(wish/comment) + target_id、reporter（voter_key 或 user_id）、reason（≤200）、status(pending/dismissed/actioned)；举报 mutation 频控 10/15min/IP。
  2. admin：`flashbackAdminSetWishHidden`（复用 quote_license set_hidden 模式）；下架时若作者累计被下架 ≥1 次 → 置 `wishes_review_required_at`；该作者新公开愿望默认 hidden 待审，admin 放行清除 hidden。
  3. admin 看板新 tab「愿望」：新愿望列表（含 listed 状态）、举报队列（pending 优先）、附议留言聚合（按愿望，含出力分布与**提交者登录账号 phone/email**——KTD5：仅 admin 面板展示、仅供对接、公开响应禁出）、一键下架/放行/驳回举报。
- **Test scenarios**：
  - 举报写入与频控；同人同目标默认 1 条（重复举报幂等承接，阈值见 Open Questions）
  - 下架 → 公开面消失；放行 → 恢复；信用降级作者新愿望默认待审
  - **联系方式字段仅 admin 查询返回；公开与成员面响应断言无 phone/email 渗漏**
  - admin 面非管理员访问被拒（fail-closed 回归）
- **Verification**：backend + web 测试全绿；admin 面 ego-browser 走通下架/放行。

### U6. 公开 GraphQL 契约与上线门

- **Goal**：公开匿名读面与公开写面就位，门控默认关。
- **Requirements**：R15、R16、R19、R30、R31
- **Dependencies**：U2、U3、U5
- **Files**：`backend/lib/cgc_2046/flashback/public.ex`（新增 wishes 公开查询）、`graphql_schema.ex`（`flashbackPublicWishes` / `flashbackExpectWish` / `flashbackReportWish` / endorse 改造挂载）、`config/config.exs` + `config/runtime.exs`（`flashback_wishes.public_enabled`）、`web/lib/graphql/flashback.ts`、契约测试
- **Approach**：
  1. `flashbackPublicWishes(city, item, seed)`：过滤 `listed_at + hidden_at + deleted_at + visibility=="public"`；返回 id、内容、署名快照、城市、**期待数（`COUNT(expectations)`）与附议数 + 出力聚合**（M 人附议：场地 ×a · 组织 ×b，**不返回留言、不返回 phone/email 等个人信息**）、expected_by_viewer（只看 expectations：登录查 `u:` + 入参 `a:`）、endorsed_by_viewer（登录）；**排序 = KTD10 带种子加权随机**（seed 缺省 = 当日日期 + 入参 voter_key，翻页经 offset 稳定）；`item=<wish_id>` 单条直达查询供分享（不参与排序）。
  2. `flashbackExpectWish` / `flashbackUnexpectWish`（公开，KTD2 key 判定 + 双窗限频）、`flashbackReportWish`（公开，频控）。
  3. KTD6 门控：`public_enabled=false` 时公开查询返回空 + `collecting` 标记（页面显示收集态）；成员面（capsule）不受门控。
- **Test scenarios**：
  - 门开/关两态查询行为；私密/未 listed/已下架/已撤回愿望不出现在任何公开查询（含 item 直达）
  - 双指标：期待数只随 expect/unexpect 变化、附议数只随 endorse/cancel 变化；聚合分布数值正确且无留言与联系方式泄露
  - **KTD10 排序：固定 seed+权重顺序确定可断言；换 seed 重洗；构造权重极大者必居首（`k→0` 上界）；`u` 裁剪下界防 `ln(0)`；缺省 seed 日级轮换（注入时钟断言）**
  - expected_by_viewer 匿名/登录两态正确；endorsed_by_viewer 登录态正确
- **Verification**：backend 测试全绿；契约测试通过。

### U7. Web 许愿树公开页

- **Goal**：原型许愿树视图生产化，接真实数据。
- **Requirements**：R15–R19、R21–R24、R30
- **Dependencies**：U6
- **Files**：`web/app/[locale]/flashback/wishes/`（新独立路由，KTD8）、`web/components/flashback/`（共享：地图、城市钉条、开场骨架、失效视图；新增：愿望阅读区、期待按钮、举报入口、换一批入口、收集态/空态）、`web/messages/*.json`、vitest 测试
- **Approach**：
  1. 移植原型 wishes 视图：纸签地图、按城阅读区、❤️ 期待（voter_key，乐观更新**失败按 wishId 函数式回滚——禁止整组快照回滚**（#806 F2 教训），服务端校正同函数式 updater）、聚合出力分布展示、**「换一批」重洗入口（KTD10：传随机 seed 立即重洗；缺省当日序翻页稳定）**。
  2. **路由（KTD8 定案）**：`/flashback/wishes` 独立路由；`?city=` 入 URL，voices↔wishes 互跳带 city（R21）；开场播放标记用 localStorage 两页共享不重播（KTD8，与批 1 `flashback.voicesIntroSeen` 同机制）；`?item=<wish_id>` 直达复用 #808 的 direct 状态重置模式（network-only 校验 + prop 变化同步）。
  3. 失效视图：已撤回/下架/不存在 → **统一文案「这个愿望目前无法查看」**（不区分撤回与下架，不替原因代言）+「看看这棵树」入口（与批 1 U4 金句失效页对称）。
  4. 举报入口（愿望卡与留言）；「附议 · 我能出力」按钮 → 引导去小程序浮层（KTD7：小程序码 + `wishId` 深链说明）；「写下我的愿望」入口 → 未登录走登录/找回引导，已认领校友开 U8 表单。
  5. 收集态（门关闭）：「愿望正在收集中」+ 写愿望 CTA；空态文案；i18n 全量；减少动态效果分支沿用。
  6. **#806 F2 顺手修复**：`voices-wall.tsx:339-371` 与 `public-home.tsx:67-101` 两处点赞回滚改为按 quoteId 函数式回滚（issue 内既定修法，与本批同代码路径，一并收口；F1 sync 重复行不在本批）。
  7. 回响相关 UI（筛选/卡片）**不在本批**，页面结构预留。
- **Test scenarios**：
  - 期待/取消乐观更新与服务端校正；**并发失败场景：两并发期待后到达者失败，先到者的校正计数不被回滚（#806 F2 验收序列）**
  - **「换一批」：点击后顺序变化，当天未点击时翻页顺序稳定（结构断言）**
  - 举报提交成功与频控提示
  - item 直达与失效页两路径；**软导航回树后 prop 变化不残留 direct 态（#808 回归）**；双页切换城市保留（`?city=` 结构断言）
  - 收集态与空态渲染；手机 390 无横向溢出、动作不被工具条遮挡
- **Verification**：`pnpm vitest` 绿；ego-browser 双端结构断言 + 交互走通 + 截图；`pnpm build` 通过。

### U8. Web 写愿望表单扩建

- **Goal**：Web 端已认领校友可写生产级愿望，提交结果分态反馈。
- **Requirements**：R16–R18、R32
- **Dependencies**：U7
- **Files**：`web/components/flashback/wish-frames.tsx`（`WishFormModal` :168-267 改造，复用进树页）、`web/lib/graphql/flashback.ts`（CREATE_WISH 入参扩展）、`web/messages/*.json`、测试
- **Approach**：
  1. 表单加署名选择（匿名 / display_name，预览明示「将以 display_name 实名展示」，不暗示法定名，R17）+ 期望地选择（候选集）+ 公开/私密选择（**默认公开档**（2026-09-22 已定）+ 选项说明**加粗**明示「公开 = 任何人可见」，选中即随提交带 `publicListingConsent=true`（KTD1 契约）；**私密档说真话：「仅自己可见；平台做内容安全审核时会看到」**——私密愿望对平台 MCP 治理面本就可见（`admin_list_wishes.ex:38-55`），不写「只有自己知道」这种假话）+ 机审拒绝文案（`flashback_content_rejected` →「这句话没能挂上树，换种说法试试」）。
  2. **分态提交反馈（R18）**：公开 + 门开 → 镜头定位所选城市、新纸签出现（原型 J5 行为）；公开 + 门关 →「愿望已挂上，树开放时所有人可见」；私密 →「已存入你的长廊：只有你能看到它，平台仅会在内容安全审核时查看」；信用降级待审 →「已提交，审核通过后挂上树」。**任何分态都不假装纸签已公开出现**。
  3. 本人查看与撤回入口（R18）：提交反馈与「我的愿望」处可找到自己的愿望（含私密/待审分态标记）并可撤回；撤回后公开面即不可见（旧链接进 U7 失效视图）。
- **Test scenarios**：
  - 署名两档预览与提交值正确；机审拒绝显示文案且不丢草稿
  - **四种提交分态各自反馈正确（公开门开/门关/私密/待审），门关闭时 listed 正常写入但不进公开查询；私密档默认态为公开且说明文字加粗（结构断言）**
  - 私密愿望不进公开列表；撤回后公开查询（含 item 直达）不可见
  - 未认领登录用户被引导认领；额度耗尽文案（既有 `flashback_wish_quota_exceeded`）
- **Verification**：vitest + ego-browser 走通写→找到→撤回。

### U9. 小程序：viewer 开放 listed 段 + 期待 + 附议表单 + 订阅授权

- **Goal**：登录用户（含非校友）在小程序可发现公开愿望、期待、附议；成员面动作升级为新模型。
- **Requirements**：R19、R30、R31、R16
- **Dependencies**：U3、U6；#790（小程序 mock transport 缺 wish 写面四 mutation——本单元测试依赖；若 #790 未先行收口，本单元顺手补齐）
- **Files**：`miniprogram/src/pages/flashback-corridor/index.tsx`（viewer 门禁开放与愿望卡/弹层 :542-590, :808-853）、`miniprogram/src/domain/share-route.ts`（`wishId` 深链解析，`resolveAppShowRoute` :75-122 扩展）、`miniprogram/src/domain/subscription.ts`（新增 `flashback_wish_echo` 场景与触点）、`miniprogram/config/index.ts`（模板 env 槽）、`miniprogram/src/api/operations.ts` + `api/real.ts`（ExpectWish / EndorseWish 改造 / CancelEndorse）、`miniprogram/src/domain/flashback.ts`（voter 设备键生成）、`domain/error-copy.ts`、相关测试
- **Approach**：
  1. **viewer 开放（P1b）**：长廊 viewer 态（登录、无档案）显示 listed 公开愿望段（只读样式与成员面一致，KTD6 门关闭期间照常显示作积累）；未登录路人维持现状 viewer 统计 + 登录引导。成员面（member）愿望段现状不变。
  2. **`wishId` 深链**：`resolveAppShowRoute` 增加 wishId 解析 → 长廊打开并定位该愿望 modal；Web 附议引导浮层（U7）与后续分享卡片共用此入口。
  3. **期待**：愿望卡加 ❤️，voter 为 `a:` 设备键（小程序 storage 持久化生成，口径同 `web/lib/flashback-voter.ts`）；登录后服务端强制 `u:` 判定与 anonVoterKey 合并由 U2 保证，客户端照常传设备键。
  4. **附议 · 我能出力**（KTD3）：未登录 → 登录页（手机号一键登录，`returnUrl` 回跳范式现成）→ 回跳后重开愿望 modal；表单 = 接收回响通知（默认勾选 → `requestTouchpointConsent` 走既有订阅基建——**grant 唯一来源**，模板未配置时 fail-closed 隐藏勾选）+ 我能出力（场地/组织/讲课分享/物资/其他留言）+ **联系方式告知文案（「提交即同意主办方通过你账号绑定的手机号/邮箱与你联系对接」**KTD5）+ 提交；已附议态与取消（含「已取消附议」正确语义——顺带替换现状 :296 处无取消语义的错误 toast）。
  5. 期待数 + 附议聚合双指标展示与 Web 一致（U6 契约直读）。
  6. 目标资格与按钮态按 KTD9：viewer 只见 listed 愿望的附议入口；offline/错误分支文案走 error-copy。
- **Test scenarios**：
  - viewer 进入长廊可见 listed 愿望段并可期待；未 listed 成员愿望对 viewer 不出现在任何列表与深链
  - 期待/取消计数正确；附议全流程（未登录 → 一键登录 → 回跳 → 授权 → 提交 → 聚合更新，**授权余额全程只 +1**）；**取消附议只减附议数、期待数不受影响（双指标分离）**
  - 存量 `p:` 附议者登录后视为已附议（归并不双计）
  - `wishId` 深链：有效 → 定位 modal；失效 → 得体提示
  - 模板未配置时表单无通知勾选且可正常提交；机审拒绝文案
- **Verification**：小程序测试绿；微信开发者工具编译预览走通；真机或模拟器交互验证。

### U10. 小程序：写愿望扩建

- **Goal**：小程序写愿望与 Web 同规则，公开授权明示。
- **Requirements**：R16–R18、R32
- **Dependencies**：U4、U8（规则对齐）；#790（同 U9，CreateWish 扩展测试依赖 mock 写面补齐）
- **Files**：`miniprogram/src/pages/flashback-corridor/index.tsx`（许愿 sheet :878-916）、`miniprogram/src/api/operations.ts`（CreateWish 入参扩展）、`domain/error-copy.ts`、测试
- **Approach**：许愿 sheet 加署名选择与期望地选择（与 U8 同规则同文案：默认公开档 + 加粗明示；私密档说真话「仅自己可见；平台做内容安全审核时会看到」）；公开档选中即带 `publicListingConsent=true`（KTD1 契约）；机审拒绝文案；**分态提交反馈与 U8 四态一致**（含待审与门关态，不假装纸签已公开出现；本人可在私愿帧找到并撤回）。
- **Test scenarios**：与 U8 对称（署名/机审/私密边界/额度/四态反馈/撤回/默认加粗档）。
- **Verification**：小程序测试绿；开发者工具走通。

## Scope Boundaries

**本批包含**：WISH/EXPECTATION/ENDORSEMENT/REPORT 模型与迁移、机审接入（现有入口 + 附议留言）、审核体系与 admin 管理面、公开 GraphQL 契约与上线门、KTD10 排序算法、Web 许愿树独立路由公开页与写愿望表单、小程序 viewer listed 读面/期待/附议/写愿望扩建、附议身份升级（登录承诺模型，成员面匿名点击计数由期待承接）、#806 F2 回滚修复。

**本批不包含（非目标）**：

- Echo 回响本体（状态机、admin 发布、通知发送触发、回响卡 UI）——生产第三批，依赖本批的订阅授权链路
- 小程序树页**地图**读面（渲染方案未验证，与小程序金句墙一起另立项；viewer listed 列表读面属本批）
- 作者正反馈（R34）、分享度量 SHARE_EVENT、金句排序时间衰减
- 写愿望资格扩大到非校友（未决项，维持已认领校友；附议不受此限）
- 作者编辑愿望（维持撤回重发；编辑规则未决）
- #806 F1（quote sync 重复行唯一约束）——独立归宿

### Deferred to Follow-Up Work

- token-only 机审长尾收口（未认领 token 持有者的愿望/留言 skipped）：量纲先经 telemetry 观察，再评估 token 入口登录化（claim 会作废 token，需产品决策）
- 历史愿望的作者回访征询（「愿意挂到公开树吗？」）——授权不扩大红线下的存量激活，另立小批
- 金句/档案公开面的举报入口（本批举报表按 target_type 通用设计，UI 只接愿望）
- 附议留言公开化（需审核能力具备后，R31）
- 小程序发现页入口卡与分享卡片物料（R26 小程序部分）
- 期待/附议的跨设备账号级合并完整规则（本批：登录期待强制 `u:` + anonVoterKey 同设备合并；跨设备匿名键合并不在范围，与 LIKE 同口径）

## Open Questions（执行时解决，不阻塞开工）

**已定（2026-09-22 用户对齐拍板）**：公开树排序 = KTD10 带种子加权随机（本期实现，不上平铺序）；期待/附议双指标分离（KTD2）；公开/私密**默认公开 + 加粗明示**；新附议一律登录（KTD3）；私密文案说真话（平台审核可见，U8/U10）。

**剩余默认（否决请说）**：

- 期望地候选集：复用既有城市列表（名册 ∪ 场次 ∪ 公开愿望城市），不允许自由输入（用途：愿望要钉到地图/树的城市坐标 + 阅读区按城分栏，自由文本无法定位且易产生「上海/上海市」脏数据）。
- 展示名变更不回溯旧愿望（`signature` 创建时定型；本批新规则，QUOTE 无此先例）。
- 上线门开启时机与「不冷清」的运营口径：admin 目测手动开，不设自动阈值（机制见 KTD6）。
- 举报同人同目标默认幂等 1 条；频控 10/15min。
- **地图审图号**：树页与金句墙共用地图组件，批 1 遗留的审图号确认同为上线前运营确认项。
- 附议联系方式告知文案的最终措辞（执行时随 U9 落，原则：用途 + 字段 + 仅主办方可见）。
- `flashback_wish_echo` 模板文案与申请排期（外部依赖，Echo 批前必须就位；申请任务已派 ops agent 跟进）。

## Verification Contract

- `cd backend && mix test` 全绿（含迁移、期待/附议/举报/机审/门控/排序）；`mix format --check-formatted`、编译零警告。
- `cd web && pnpm vitest` 全绿；`tsc --noEmit` 与 eslint 通过；`pnpm build` 通过。
- `cd miniprogram && pnpm test` 全绿；微信开发者工具编译预览通过。
- ego-browser 双端实测：树页读/期待/换一批/举报/写愿望四分态/失效页/收集态；admin 下架与放行；小程序模拟器 viewer 登录→附议→取消全流程。
- 授权边界专项：私密、未 listed、已下架、已撤回愿望不出现在任何公开查询与页面（含旧链接与 wishId 深链）；附议留言与联系方式（phone/email）不出现在任何公开与成员面响应。
- **公开授权契约专项**：无 `publicListingConsent` 的 `visibility=public` 请求 `listed_at IS NULL`（旧客户端回归）；带 consent 才进公开树。
- 合规专项：愿望/留言/附议留言三态机审（通过/拒绝/故障）行为正确；token-only openid 缺口走 skipped + telemetry。
- **计数专项（双指标分离）**：期待数只随 expect/unexpect 变化、附议数只随 endorse/cancel 变化；同一人先匿名期待后登录附议 → 期待 1 + 附议 1（可接受）；登录 expect 带 anonVoterKey 合并匿名行不双计（同一计数器内）；存量 `p:` 附议计入附议数与聚合。
- **排序专项（KTD10）**：固定 seed+权重 → 精确顺序断言；换 seed 顺序变化；权重极大者必居首（`k→0` 上界性质）；`u` 裁剪防 `ln(0)`；缺省 seed 当天稳定、跨天轮换（注入时钟）；「换一批」端到端重洗。
- **订阅单源专项**：附议 + 授权全流程余额只 +1（endorse 后端零 grant 调用断言）。
- **并发专项**：两并发期待后到者失败，先到者服务端校正不回滚（#806 F2 验收序列，voices-wall/public-home/树页期待三处同规）；wish 失效页软导航 prop 重置（#808 回归）。

## Definition of Done

- 上述 Verification Contract 全过；
- 路人在 Web 树页可读公开愿望、❤️ 期待、「换一批」重洗、举报；**登录非校友（viewer）在小程序长廊可见 listed 愿望段并可走完登录回跳→附议（含订阅授权意愿）→取消附议**；
- 已认领校友在 Web 与小程序均可写愿望（署名/期望地/公开私密明示 + consent 契约），机审拒绝有体面文案，四种提交分态反馈正确且本人可找到可撤回；
- admin 可看板巡检（含附议留言与登录账号联系方式）、一键下架、放行；信用降级作者先审后发；
- 上线门默认关，开 env 即公开面生效；
- #806 F2 三处回滚修法落地，F2 issue 按验收口径关闭；
- PR 以 merge commit 合入 develop（4 checks 绿）；U4 独立 PR 提前合。
