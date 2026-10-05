---
title: "Notification Inbox #232 - Plan"
type: feat
date: 2026-10-03
artifact_contract: ce-unified-plan/v1
product_contract_source: "issue-232-product-decision-2026-10-03"
execution: code
---

# Notification Inbox #232 - Plan

## Goal Capsule

- **Objective：** 用户在「我的」查看最近 30 天系统已生成并接受的通知；换设备后历史和已读状态仍一致。
- **Means：** 在既有通知接受/入队边界同步写独立 Ash 收件箱资源；沿用现有 outbox、worker、Consent，不新增投递管线。
- **Authority：** 当前用户指令 > issue #232 的 2026-10-03「产品决策：通知收件箱 v1」评论 > 真实代码与项目约定 > 原 issue 建议/早期 backlog。产品口径不重新讨论。
- **Approval：** 本文供编排者审核，不是实施授权。获明确实施批准后才建 `.worktrees/232-notification-inbox`；主 checkout 保持 `develop`。
- **Ownership：** 实施主控负责代码与证据；用户是编排者及独立交付 reviewer。包含 migration，最终合并必须人工执行。
- **Stop conditions：** 未批准不改仓库；不 commit/push/PR/merge/auto-merge/deploy，不读取凭证文件，不修生产数据，不接管 #985 工作。

---

## Product Contract

### Summary

新增用户私有通知收件箱，服务端保存用户可见快照及 `read_at`。
微信「我的」和小红书已有「我的」入口使用相同服务端契约；本地只缓存服务端返回的数据。
收件箱表达系统接受通知，不表达渠道已送达，也不替代业务详情的实时状态。

### Problem Frame

现有 `RealApi.getNotifications()` 只读账号隔离的 local storage；换机无法读取历史，服务端没有 feed/read-mark。
原 issue 所称 fire-and-forget 已过时：当前有 durable `NotificationDelivery` outbox、`Delivery.enqueue` 与 `DeliveryWorker`。
将该 outbox 直接开放给用户会泄漏内部渠道数据，且一用户多身份产生多行，不满足收件箱语义。

### Requirements

**存储与读写**

- R1. 通知保存 30 × 24 小时；读取时立即隐藏过期行，日清理物理删除；过期不承诺恢复。
- R2. 按 `inserted_at DESC, id ASC` 确定性 keyset 分页；时间相同不漏、不重复。
- R3. `read_at` 是唯一已读事实；`markNotificationRead` 幂等、并发安全，多设备读取同一结果。
- R4. 读与已读仅限 actor 本人，平台管理员/工作台管理者也不能读取别人的收件箱；恶意 OR filter 不能扩大行集。

**生产与安全**

- R5. 写入时点为通知成功接受/入队的事务提交，不等待 provider 送达。
- R6. 同一来源、同一通知类型、同一用户，身份扇出只产生一份站内记录；来源去重不依赖 provider 或身份列表。
- R7. feed 写入、查询及已读不消费 Consent，不触发渠道发送；用户未订阅仍能看到已经生成的记录。
- R8. 存储仅限主键、用户归属、type、精简用户可见 payload、可选 deep_link、read_at、inserted_at；不复制 raw data/job_meta/provider 响应/身份 UID/授权头/cookie/验证码/重置密钥。
- R9. 仅接现有 registry 中已有业务通知，不新增信号、通知场景或邮件历史；精确清单见 Type Mapping。

**客户端与交付**

- R10. 服务端优先；storage 仅做账号隔离的缓存/fallback，不再将本机操作回执写成通知历史。
- R11. 切换账号、退出、认证失效及晚到异步响应不能泄漏或复写另一账号数据。
- R12. 覆盖 loading/empty/error/retry/分页/已读失败反馈/accessibility；deep link 只允许站内安全目的页。
- R13. migration、resource snapshot、SDL、operation 和小程序 codegen 同一真实契约提交；先红后绿、变异验证、真实 HTTP 与小程序 GUI 均提供证据。

### Key Decisions

- **30 天而非 7/90 天。** 产品权威评论已定；Governs R1。
- **服务端已读而非本机事实。** 换设备后仍一致；Governs R3、R10。
- **接受记录而非送达回执。** provider 失败不得移除已接受记录；Governs R5、R7。
- **快照白名单而非渠道原始载荷。** 禁止敏感字段进入新表/API/cache；Governs R8、R9。

### Scope Boundaries

- 不做 delivery dashboard、delivery 回执、provider 成功率、跨渠道投递可靠性重构。
- 不做 password-reset/认证邮件历史、纯交易邮件历史、90 天归档、旧 outbox 回填、旧 local storage 导入。
- 现有支付/退款**订阅通知**属于 registry 既有类型，纳入快照；这不等于导入支付邮件或建立交易流水。
- 不新增业务通知；现有生产方未生成/未接受的通知不凭查询补造。
- `tt` 当前无 profile 页，不新增「我的」页面、Tab 或通知业务。共享 API 支持三平台；有现成「我的」的 weapp/xhs 展示收件箱。
- 不碰 #985 的 backend auth/rate_limit、web 支付 redirect、CI/sync workflow、根 CHANGELOG。本次实施完成后的 changelog 整合由编排者在共享文件协调后完成；本任务先更新现有领域/验收文档。
- 不新增依赖、环境变量、服务、feature flag、轮询发送器、重试框架或永久幂等墓碑。

---

## Planning Contract

### Evidence and Reuse

以下为已读源码依据，非旧 issue 推测：

| 现有模块/路径 | 证据与复用方式 |
| --- | --- |
| `backend/lib/cgc_2046/notifications/fanout.ex:108-174,214-235` | `deliver` 丢弃 receipt 恒返回 `:ok`；receipt 是入队结果而非送达；durable 路径目前逐用户调用 Delivery，并提前跳过全无能力身份。 |
| `backend/lib/cgc_2046/notifications/delivery.ex:21-79` | user × identity 的稳定哈希去重；outbox 行与 Oban insert 在 Repo transaction 内；sent/failed 终态不复活。 |
| `backend/lib/cgc_2046/notifications/notification_delivery.ex:9-30,95-102` | 是内部投递资源，含 raw data/job_meta/identity；读仅 PlatformAdmin，不能作为 inbox。 |
| `backend/lib/cgc_2046/notifications/delivery_key.ex:14-125` | 22 个 Fanout durable 键的事件公式唯一真源；审批结果、活动提醒、周期停滞等已有来源键。 |
| `backend/lib/cgc_2046/notifications/notification_worker.ex:38-293` | registry 为通知类型唯一真源，27 个不同 template_key，approval_reminder 两面共用一个 key。 |
| `backend/lib/cgc_2046/notifications/workers/schedule_changed_fanout_worker.ex:32-69` | 改期直接走 Delivery，latest-wins，来源键含 fanout Oban job id；只挂 Fanout 会漏。 |
| `backend/lib/cgc_2046/events/qualification.ex:44-90,106-143` | 成班结果直接走 Delivery；与 qualification CAS 在同一 Repo transaction，参与者/管理腿既有不同类型及键。 |
| `backend/lib/cgc_2046/flashback/wish_echoes.ex:255-317` | 唯一直插 NotificationWorker 的 wish echo 使用 Fanout receipt，外层事务同时写一次性业务标记；零身份在生产方跳过。 |
| `backend/lib/cgc_2046/notifications/consent.ex:38-75`、`service.ex:17-35` | Consent 原子 take 在发送时，失败 refund；feed 不引用这两个写接口。 |
| `backend/lib/cgc_2046/notifications/subscriber.ex:19-39`、`workflows/signal_subscriber.ex:37-53,199-227` | enrollment/speaker 是 claim_first，有现成 at-most-once 缺口；本期不改 claim 机制，不承诺补发。 |
| `backend/lib/cgc_2046/payments/order.ex:227-235,625-631` | actor-only action + 单一 policy expr 的先例，无 admin 放行分支。 |
| `backend/lib/cgc_2046/admission/enrollment.ex:304-308,536-538` | actor filter、时间+id keyset 排序模式。 |
| `backend/test/cgc_2046_web/graphql_enrollment_read_policy_test.exs:20-82` | 恶意 OR filter 的真实 GraphQL 回归模式。 |
| `backend/lib/cgc_2046/accounts/workers/login_artifact_pruner_worker.ex:17-49` | maintenance Oban 清理惯例、UTC naive 参数匹配 PG timestamp 的已有教训。 |
| `backend/lib/cgc_2046_web/graphql_schema.ex:19-35` | AshGraphql domain 注册与自动 SDL 生成；当前 Notifications 未注册。 |
| `miniprogram/src/api/real.ts:836,845,855,865,873,975-977` | 当前 5 处 appendLocalNotification 是操作/授权本机回执；getNotifications 读本机。切换后全部清理。 |
| `miniprogram/src/state/accountState.ts:17-34,46-64` | active user、按账号存储、注销清理可复用；旧通知格式不能当新缓存。 |
| `miniprogram/src/pages/profile/index.tsx:23-35,70-79,144-157` | 当前 session/feed 并发读、本机列表、logout UI 清空；并发读需改为先确认 session。 |
| `miniprogram/src/domain/platform-pages.ts:20-112,120-141` | 已注册页面与安全 returnUrl 为路由单源；xhs 使用 profile-lite，tt 无 profile 页。 |

框架已锁定 Ash 3.33.11、AshGraphql 1.11.0、AshPostgres 2.13.1、Oban 2.23.1（`backend/mix.lock`）；无需升级。
采用官方内建 policy FilterCheck、keyset、原子 update 与同 Repo 事务入队，不自造游标/授权判断。
参考：[Ash pagination](https://hexdocs.pm/ash/3.33.11/pagination.html)、[Ash policies](https://hexdocs.pm/ash/3.33.11/policies.html)、[AshGraphql DSL](https://hexdocs.pm/ash_graphql/1.11.0/dsl-ashgraphql-resource.html#graphql-queries-list)、[Oban 2.23.1](https://hexdocs.pm/oban/2.23.1/Oban.html)。

### KTD1. Independent Inbox Resource

新增 `Cgc2046.Notifications.Notification`，表 `notifications`；不修改 outbox schema，不暴露 Delivery。
字段：

| 字段 | 契约 |
| --- | --- |
| `id` | 私有来源 tuple 的 SHA-256 小写 hex，string 主键；该技术主键兼做幂等约束，不另存 raw source key。 |
| `user_id` | UUID，FK users ON DELETE CASCADE；resource references 同为 delete；API 不返回此归属，也不接受客户端归属。 |
| `type` | registry 已有 template_key，string；无用户输入动态 atom。 |
| `payload` | 仅 `title`、`body` 两个 string；私有存储，不暴露任意 JSON blob。 |
| `deep_link` | 可空，服务端白名单生成。 |
| `read_at` | 可空 UTC microsecond 时间。 |
| `inserted_at` | 服务端首次接受时间，UTC microsecond；重放不刷新。 |

GraphQL 公共 title/body 由 private payload 的只读计算字段提供；不新增持久化冗余列。
不加 updated_at、provider、delivery_id、identity_uid、状态或发送错误字段。
新表索引为 `(user_id, inserted_at DESC, id ASC)` 和 `inserted_at` 清理索引；PK 自带来源唯一约束。
新表无存量回填，普通事务 DDL 足够；不是对生产增长活表加索引。
内部 create/destroy 不对用户授权、不暴露 GraphQL；可信 Inbox 写入口显式关闭授权并设置服务端字段，create action 不将归属放入外部 accept。

### KTD2. One Source/User Record

来源 tuple = 固定命名空间 `notification-inbox-v1` + user_id + template_key + existing source event key；哈希前使用无歧义的 tuple 序列化，不拼接任意文本。
identity/provider/quota 不进入 tuple，正文、身份增加/删除不改变 id。
写入使用 PK upsert 且 update fields 为空：first-write-wins，保留原快照、inserted_at、read_at。

- Fanout durable：复用 `DeliveryKey.event_key`；不再复制审批/提醒公式。
- `speaker_completed`：渠道继续使用原 managers/speaker leg 键；feed 的同类型同用户去重去掉 leg，正文采用共同「分享已完成，材料已归档」，不以哪条腿先到决定不同语义。
- 直接 Delivery 的改期/成班：复用生产方 job_meta.idempotency_key；feed 同时加入 type，参与者/管理者不同类型仍为不同通知，不错误并腿。
- wish echo：使用现有 echo_id + wish_id + user_id；不含平台身份/渠道任务 id。同一 echo/user 只一条。
- 同一业务事件产生不同通知类型，如报名成功与核销码就绪，是现有两种业务通知，保留两条；「一份」约束针对身份扇出，不抹掉现有类型。

**去重生命周期：** 新表中的来源唯一性覆盖保留行的生命周期；删除正文后不另保永久收件箱墓碑。
已有 durable outbox 仍保持自己的长期来源/身份去重与终态不复活。
对于有既存 outbox 的重复调用，采用 outbox 原始接受时间判断：旧行已超过 cutoff 时不得以现在时间重建 feed；不从旧 outbox 导入历史。
无渠道 outbox 的纯站内接受行删除后，不承诺无限期来源去重；同一旧输入若在 30 天后再次被生产方重新接受，可能形成新的站内记录，绝不恢复旧 read_at。
这是不额外保留用户关联永久源键的保守取舍，审核者应重点检查；本期不声称永久 exactly-once。

### KTD3. Acceptance and Transaction Boundary

最小方案是「独立表 + 现有接受事务内 append」，不是 Worker 发送后写，也不是把 outbox 投影成 feed。

```text
Existing business actions / signals / periodic producers
             |
             +--> Fanout (recipient user resolution)
             |        |
             |        +--> durable keys --> Delivery.enqueue
             |        +--> wish echo direct Oban insert
             |
             +--> direct Delivery (schedule / qualification)

Per-user acceptance transaction
  safe InboxSnapshot --> Notification insert-if-absent
  existing Delivery rows + existing Oban jobs
  commit both / rollback both
             |
             +--> existing DeliveryWorker / NotificationWorker
                         --> Service --> Consent --> provider

GraphQL actor read / mark-read --> Notification only
  --> RealApi --> account-scoped cache --> shared Inbox panel
Daily maintenance worker --> purge Notification only
```

**Durable：** 在 `Delivery.enqueue` 的已有 Repo transaction 内写 feed，每用户一次；该方法也覆盖 direct Delivery 的三种成班结果与改期，不搬生产方。
Feed append 位于渠道接受完成之后、提交之前；任一 outbox/Oban/feed DB 写失败，整个用户的接受事务回滚并沿既有异常出口报告失败。
所有身份必须在同一用户事务内，第二身份失败不得留下首身份 job 或 feed。
不把所有用户合成一个新大事务：Fanout 批量调用现状是逐用户提交；第 N 用户失败时前 N-1 已接受的记录存在，receipt 可返回 enqueue_failed，重试靠来源去重。
已有外层事务（qualification、wish echo）保留：外层回滚时里面的 feed/outbox/jobs 同时消失；不从内部 rescue 吞掉需要回滚的 DB 异常。

**直插 wish echo：** Fanout 的现有直插接受段增加同 Repo transaction 的 Inbox append；Oban args unique 命中只按既有 receipt 规则计数，不为 feed 增加 count。
Feed DB 失败返回 enqueue_failed，保持一次性业务标记不提交。
生产方没有接受、零身份提前 skip 的 echo 不生成 feed，不调整其授权业务。

**无 quota：** 生产接受仍落 feed/outbox/job；后续发送 Consent exhausted 可使 delivery 失败，feed 保留；查询/mark-read 不调用任何发送或 Consent 写方法。

**真零身份：** 显式已解析 user tuple 的 durable 调用落一条 feed + 既有 nil identity 哨兵 outbox/job；保留渠道重解析逻辑及 receipt count=0。

**身份全部无能力：** 仍接受一条站内记录；不创建 channel outbox/job，不将 wechat_web 伪装成真零身份，不造死信。receipt count 仍为 0。
Fanout 不应提前跳过这类用户，而应将**原始** identities 交给 Delivery；渠道 capable 过滤仍由现有 Service 谓词定义，不能先过滤成 [] 误造哨兵。

**管理者身份为空：** Fanout.managers 保留已命中角色的 user_id，map 值可以 []；采用现有 membership/role 选择规则，不扩大角色权限、不新增业务收件人。

**生产方本来 skip：** LearningProgressWorker 的零身份 skip（现有 #902 决定）和 wish echo 的零身份 skip 保留；这是未生成/未接受，不是 feed 因 Consent 被拒。
本期不通过查询补造、不改生产方调度/claim。

**失败承诺边界：** `Fanout.deliver` 现有恒 :ok/best-effort 与 claim_first 缺口保留并成文，不能声称业务事务必定有收件箱记录。
已成功接受的通知有 feed；接受失败则没有 feed，已有日志/telemetry 负责显示失败。
不添加可靠投递重构或假兜底记录来掩盖这个边界。

### KTD4. Public GraphQL and Actor Isolation

`Notifications` 增加 AshGraphql.Domain extension，根 schema 注册 domain；只对新 Notification resource 加 AshGraphql.Resource，不让 Consent/Delivery 自动获得 API。

公共契约：

- `notificationFeed(first: Int, after: String)`：默认 20、最大 50；固定 keyset 排序；返回原生 `KeysetPageOfNotification` 的 results、startKeyset、endKeyset，客户端不请求 count。
- 每条为 `id: ID!`、`type: String!`、`title: String!`、`body: String!`、`deepLink: String`、`readAt: DateTime`、`insertedAt: DateTime!`。
- `markNotificationRead(id: ID!)`：原生 AshGraphql update result/errors 形状；无 readAt/userId 输入，result 返回该通知及服务端 readAt。
- 关闭 generated sort/filter 外部输入，避免客户端改排序。原生 keyset 如仍生成 before/last，沿框架保留分页参数，但小程序仅使用 first/after；不自造分页 DSL。
- 无独立公开 get(id)、create/delete、unread count、批量已读、MCP inbox 工具。

resource 主 read/read-feed 均含 actor SQL filter 和实时 cutoff；policy 对 read/update 只有本人 expr，不加 always/admin/manager bypass。
没有 actor 明确 forbidden；他人 id/不存在 id/过期 id 的 read-mark 返回相同 not-found 语义，不泄漏存在性。
mark-read 的预读用同一受限 primary read，mutation 本身也必须检查 owner+未过期，不能只靠预读。
直接 Ash query 的 `OR(id=A,id=B)`、`OR(user_id=A,user_id=B)` 仍与 policy AND；HTTP 强行提供 filter/sort 被 SDL 拒绝。
同时验证直接资源 OR 和 HTTP 参数拒绝，不能用「没有 filter 参数」替代资源行隔离测试。

mark-read 使用 Ash atomic update：read_at 空则取服务端 now，否则保留 DB 当前 read_at；不以加载时旧值执行普通 set_attribute。
并发两设备首次 mark，只能得到同一个首次 read_at；重复 mark 不改快照或 inserted_at。

### KTD5. Retention and Pagination

单请求捕获服务端 UTC now，cutoff = now - 2,592,000 秒。
可见条件 `inserted_at > cutoff`；正好等于 cutoff 视为过期，mark-read 同条件。
每日 purge 删除 `inserted_at <= cutoff`；清理未运行不会延长可读窗口。
采用 UTC microsecond timestamp 一致类型；PG timestamp-without-timezone 参数使用等精度 naive UTC，不能截秒造成边界漂移。

固定 `(inserted_at DESC, id ASC)` 加同顺序联合索引，游标由 Ash 生成，客户端只透传。
分页中有新记录插入顶部，下一页不重复已读上一页；同时间 id 打破平票；已删除 cursor 仍按游标值继续；非法/超大 cursor 由 Ash 拒绝，不手动 unsafe binary_to_term。
每页重新计算 cutoff，跨页期间过期的通知消失，不为了冻结列表额外保留过期正文。
无 count 全表统计；客户端页满时显示「加载更多」，最后一次空页或少于请求数时结束。

`NotificationPrunerWorker` 放 `notifications/workers/`，复用 maintenance queue/max_attempts=3/unique incomplete 模式。
固定日 cron `17 3 * * *`（UTC），不加配置 knob；worker 对 resource 的内部 bulk destroy 只作用 notifications，重复执行幂等，DB 错误交现有 Oban 重试。
不会清理 notification_deliveries/consents/oban_jobs，不复制现有 Oban Pruner 的 7 天政策。

### KTD6. Safe Snapshot and Deep Link

payload 只存 plain-text title/body；title 最大 80 个 Unicode 字符、body 最大 280 个 Unicode 字符。
格式化只读取下面列出的业务字段；不使用 Map.merge(raw data)、JSON stringify 或「未知类型原样透传」。
用户可见标题/原因/安排文本可短截断；缺可选字段用固定中性文案，不查询另一套业务状态补数据。
未知 template 不改变既有投递行为，但不写 feed；本期所有 27 个 registry 类型有明确投影。
核销码通知只写「核销码已就绪，请到我的报名查看」，不保留码值。
日期按既有用户展示习惯格式化；不序列化 venue 原始 map，改期 venue 用 `Events.Venue.text` 同类投影。

deep_link 由本地白名单 builder 生成，不读取 caller 的任意 URL；只允许：

- `/pages/my-enrollments/index`；
- `/pages/event-detail/index?id=<业务 event UUID>`；
- `/pages/workspace/index`；
- `/pages/flashback-wishes/index?wishId=<业务 wish UUID>`。

其中业务 UUID 必须合法、query 使用编码；无合法 UUID 时留空或使用无参列表页。
不支持 http/https、scheme、protocol-relative、web-view、登录/支付/领卡/claim/returnUrl/scene/token 参数，也不执行任意重定向。
客户端再以 `pageRegistered` + **同类精确参数白名单**确认目标在当前端注册；单独 safeReturnUrl 不够，因为它只检查 page 名。
导航复用 `miniprogram/src/domain/tab-routes.ts` 的 isTabPath 判定：Tab 目标走 switchTab（不带 query），普通页走 navigateTo；失败显示反馈，不自动降级为外部页面。
裁剪端未注册管理目的页时不导流、不生成外链，保留通知文本和已读按钮。
目的页继续按既有授权与实体存在性检查，deep link 不是授权。

### Type Mapping

以下精确覆盖 registry 的 27 个不同 type；没有新增通知类型。
「允许来源字段」只用于生成 title/body，不原样存储这些字段；其他 keys 一律不进入新表。
P 代表 my-enrollments 无参页，W 代表 workspace 无参页，E 代表经校验 event-detail，F 代表经校验 wishes；空表示无 deep_link。

| type | 允许来源字段 | 用户可见快照意图 | deep_link | 来源键 |
| --- | --- | --- | --- | --- |
| approval_result | title, status, capacity_seq | 报名审批通过/未通过；可显示已知名额序号，不显示 enrollment UUID | P | DeliveryKey：enrollment_id + status |
| enrollment_submitted | title | 有新的待审批报名，前往工作台处理 | W | DeliveryKey：生产信号 idempotency_key |
| enrollment_completed | title | 报名成功 | P | 同上，type 分开 |
| enrollment_check_in_code | title | 核销码已就绪，请到我的报名查看；**不读入/不存 check_in_code** | P | 同上，type 分开 |
| approval_reminder | approval_deadline | 有申请待审批及可选截止时间；不复制 enrollment/sponsorship UUID | W | DeliveryKey：enrollment 或 sponsorship 现有公式 |
| event_reminder | title, starts_at, venue | 活动/课程即将开始及时间/地点 | P | DeliveryKey：目标 id + starts_at |
| event_schedule_changed | title, starts_at, venue | 活动安排已更新；时间/地点为 fanout 的 latest-wins 快照 | E | 现有 event.schedule_changed + event id + fanout job id |
| event_qualification_confirmed | title, min_participants, confirmed_count | 活动达到成班要求 | E | 现有 qualification:event id；type 分开 |
| event_qualification_underfilled | title, min_participants, confirmed_count | 活动未达到成班要求，不额外承诺退款送达 | E | 同上，type 分开 |
| event_qualification_manager | title, outcome, min_participants, confirmed_count | 管理侧成班结论 | E | 现有 qualification:manager:event id |
| event_moderator_assigned | title | 已被指派为活动主理人 | E | DeliveryKey：assigned:event id |
| event_moderator_removed | title | 活动主理人身份已解除 | E | DeliveryKey：removed:event id |
| speaker_accepted | title | 分享者已接受邀请 | W | DeliveryKey：生产信号键 |
| speaker_completed | 无自由文本必需项 | 分享已完成，材料已归档；两腿使用相同正文以便同用户合一 | 空 | 生产信号键，feed 去 leg |
| learning_stagnation | title | 学习进度提醒，不宣称课程未完成的实时结论 | P | DeliveryKey：run id + epoch 7 天桶 |
| payment_succeeded | amount | 支付成功及金额；不显示 provider/raw order | P | DeliveryKey：既有 payment signal/order key |
| payment_received | title, tier_name, amount | 收款到账及金额/活动/档位的简短快照 | W | DeliveryKey：既有 payment_received:order key |
| payment_expired | title, amount, re_enrollable | 支付订单已过期；只在现有 re_enrollable=true 时提示截止前可重报 | P | DeliveryKey：既有 expiry key |
| refund_succeeded | amount | 退款成功及金额，不等于本站再确认到账时间 | P | DeliveryKey：既有 refund key |
| refund_failed | amount | 退款未完成，请查看报名信息；不存渠道失败 reason | P | DeliveryKey：既有 refund key |
| volunteer_application_submitted | cohort_name, position_label | 志愿者申请已提交，等待初审 | 空 | DeliveryKey：生产信号键 |
| volunteer_application_interview | cohort_name, group_time | 面试安排及可选时间，运营将联系入群；不保存入群凭证 | 空 | 同上 |
| volunteer_application_training | cohort_name, training_starts_at | 训练营安排及可选时间；不保存邀请码 | 空 | 同上 |
| volunteer_application_assigned | event_title, assignment_note | 项目分配已完成及精简安排 | 空 | 同上 |
| volunteer_application_rejected | cohort_name, rejection_reason | 申请未通过及精简用户可见原因 | 空 | 同上 |
| volunteer_application_canceled | cohort_name, cancel_note | 申请已取消及精简备注 | 空 | 同上 |
| flashback_wish_echo | content_preview | 主办方收到你的提议，来看看回应及 20 字既有预览 | F | 既有 echo id + wish id + user，身份不入键 |

E/F 的 UUID 只用于安全路由，不加入正文/payload；列表不是读取任意 job_meta 的授权。
支付订阅只投影上述业务文本，不存 provider、order_id、原始交易载荷；纯邮件发送模块没有 hook。
registry 今后新增类型必须显式决定快照映射，不能通过 fallback 自动记录敏感新类型。

### KTD7. Client Source, Cache and UI

保持 `api.getNotifications` 名称，但返回结构改为 page：items、nextCursor、hasMore、source(server/cache)；增加 `api.markNotificationRead`。
NotificationItem 改为 id/type/title/body/deepLink/readAt/createdAt；删本机 read boolean，以 readAt 是否为空派生 UI。
RealApi 对后端 typed title/body/readAt/insertedAt 做边界映射；不依赖 any JSON。

先完成 getSession 并确认 user，再请求 feed，不能继续 Promise.all(getSession,getNotifications) 让前账号 activeId 参与新账号请求。
账号 epoch 在 activateAccount/clearAccountState 处统一维护；每次请求捕获 userId+epoch，返回、catch、finally 和缓存写之前都检查仍匹配。
分页/刷新另外捕获请求序号，旧刷新不得覆盖新列表；已读与刷新也需保留已读 mutation 的服务端结果，不能晚到旧列表把已读改回未读。
切换用户和 logout 立即清空 panel 状态并使 epoch 失效；晚到 A 的 feed/mark-read 既不显示，也不写 B 的 key。

新缓存 key 为 `cgc.notification_feed.v1.<userId>`；只缓存最近首屏最多 20 条服务端行及 fetchedAt，不缓存分页游标或 optimistic 已读。
激活/退出删除当前账号旧 `cgc.local_notifications.<userId>` 和旧全局 key，不迁移、不混合旧本机操作记录。
现有 lastEnrollment/pendingScene/flashback-link identity 的语义不改。

正常成功即替换首屏缓存，包括服务端空列表；分页失败保留已成功页但显示加载更多失败/重试，不拿首屏缓存覆盖分页。
仅在认证仍有效、账号不变的 transport/network 错误时读该账号缓存，并按 30 天 cutoff 剔除过期行；明确标「缓存记录，可能不是最新状态」+ 重试。
GraphQL 权限/契约/业务错误和 401/authExpired 不 fallback；认证失效清通知状态并提示重新登录。
Cache 损坏/版本不符/日期不合法时删除并显示 error，不构造假历史。

不做乐观已读或离线 mutation 队列：在线 mark 成功后采用服务端 readAt；失败显示可重试反馈，保留未读状态。
可点击安全 link；无 link/本端不支持 link 时提供独立「标为已读」按钮，不造空导航。
缓存模式仍可查看文本；标为已读必须在线成功，失败不持久化假 readAt。

共享 `NotificationInbox` panel 嵌入 profile 与 profile-lite，新增共享的理由是两处真实使用，不抽通用通知框架。
页面只留渲染与调用；分页合并、过期判定、状态转移、safe notification route 下沉 `domain/notifications.ts`。
loading 不闪现旧账号条目；empty 明示「最近 30 天暂无通知」；首次无缓存 error 用 PageState retry；刷新/mark/更多的错误各自在通知区域，不吞掉 profile 其他功能。
已读/未读用文字和样式共同表达，不只靠颜色；使用原生 Button 及可读 aria-label，提供触控尺寸、disabled/loading 反馈，标题/正文/时间能换行，不将整段正文当按钮名。
profile-lite 中使用当前已有用户会话/退出边界，不新增登录路径或改 Tab。

---

## Implementation Units

一次完整功能交付，不将只能编译的 backend/client scaffold 分别宣称可交付阶段。
以下 U1→U4 是实施顺序，不是允许中途停止的发布阶段。
预计超过 8 个文件，约 30 个源码/测试/产物路径；新增资源、快照投影、清理 worker、共享 panel 各有独立职责，没有新服务。
所有手写新文件保持 500 行以内；既有大文件只做本范围的紧凑改动，不借机重构。

### U1. Resource, Actor Contract and Retention

- **Goal / Requirements：** 落实 R1–R4、R8、R13；先写 actor/边界/并发行为测试。
- **Files：**
  - 新建 `backend/lib/cgc_2046/notifications/notification.ex`。
  - 新建 `backend/lib/cgc_2046/notifications/inbox.ex`：内部 append、cutoff、purge 的小接口，所有 query/action 保留 Ash 资源边界。
  - 修改 `backend/lib/cgc_2046/notifications.ex`、`backend/lib/cgc_2046_web/graphql_schema.ex` 仅 domain 注册。
  - 新建 `backend/lib/cgc_2046/notifications/workers/notification_pruner_worker.ex`；修改 `backend/config/config.exs` 仅日 cron。
  - 一条新 migration：`backend/priv/repo/migrations/<生成时间戳>_create_notifications.exs`；准确时间戳由 `mix ecto.gen.migration create_notifications` 生成，不在规划时捏造。
  - 生成 `backend/priv/resource_snapshots/repo/notifications/<生成时间戳>.json`、`backend/priv/graphql/schema.graphql`。
  - 新建 `backend/test/cgc_2046_web/graphql_notification_inbox_test.exs`。
  - 新建 `backend/test/cgc_2046/notifications/inbox_test.exs`、`backend/test/cgc_2046/notifications/workers/notification_pruner_worker_test.exs`。
- **Approach：** 按 KTD1/KTD4/KTD5 建表与 actor resource；raw payload 不对 GraphQL public；Ash native keyset/atomic mark-read。
- **Patterns：** Order.my_orders actor policy、Enrollment.my_enrollments 排序、LoginArtifactPrunerWorker UTC 参数。
- **Test scenarios：**
  1. A/B 两用户及 admin，对完整 ID 集做精确断言；A 的 direct Ash OR filter 不能返回 B，admin 不例外。
  2. 匿名 forbidden；其他人的/不存在的/过期的 id mark-read 同样拒绝，不能更新 user_id/readAt/payload。
  3. 同 timestamp 的至少 3 行分两页，精确次序；插入新顶部记录、删除上一页 cursor 后仍无重复/遗漏。
  4. cutoff 前 1µs、正好 cutoff、后 1µs；read/mark/purge 保持同一边界；非 UTC DB session 不产生 8 小时偏移。
  5. 两设备并发 mark-read，同一首次 readAt；第二次不改 readAt、insertedAt、正文。
  6. 过期行即使 cleanup 未跑也不可见；cleanup 两次不会删新行，不动 consent/delivery。
  7. cursor malformed/oversized、first 超限由框架拒绝；filter/sort/userId HTTP 参数未开放。
- **Verification：** 持久化/授权行为测试先红后绿；真实 HTTP 复核独立于 ConnCase，见 Verification Contract。

### U2. Existing Acceptance Hook and Safe Snapshot

- **Dependencies：** U1。
- **Goal / Requirements：** R5–R9、R13；不重做可靠投递。
- **Files：**
  - 新建 `backend/lib/cgc_2046/notifications/inbox_snapshot.ex`：27 型 plain-text 投影与白名单 deep-link builder。
  - 修改 `backend/lib/cgc_2046/notifications/delivery.ex` 与 `backend/lib/cgc_2046/notifications/fanout.ex`。
  - 更新 `backend/test/cgc_2046/notifications/delivery_test.exs`、`fanout_test.exs`；新建 `inbox_snapshot_test.exs`。
  - 在既有 `backend/test/cgc_2046/notifications/schedule_changed_subscriber_test.exs`、`backend/test/cgc_2046/events/qualification_test.exs` 增加真正生产路径 feed 断言。
  - 在 U1 新建的 `backend/test/cgc_2046/notifications/inbox_test.exs` 中，经现有 WishEchoes 实际业务接受入口补充 echo 事务/一次性标记断言，不新增其业务行为。
- **Approach：** 按 KTD2/KTD3 将 feed 纳入现有每用户接受事务；保留 caller、渠道 idempotency、stale 检查、Consent、receipt count、外层事务。
- **Test scenarios：**
  1. 同来源、同用户 3 身份产生 1 feed + 原本 3 delivery，重复调用保持 ID/正文/readAt/insertedAt 不变。
  2. 成班与改期 direct Delivery 路径都有 feed；改期重试同 job 不重复，新 debounce job 产生新记录。
  3. 无 Consent 接受有 feed，后续 exhausted/failed 不删 feed；read/mark 不增加 jobs，不改变 quota。
  4. 显式零身份为 feed+既有哨兵；全无能力身份为 feed+0 channel row/job；混合身份仅对 capable 渠道落行，receipt 数不包含 feed。
  5. 无平台身份管理者保留 user 接受记录，但普通成员仍非管理收件人；LPW/echo 生产方原 skip 不被扩张。
  6. 确定性让第二身份 Oban insert 失败或 feed insert 失败：该用户零残留；已有外层事务失败时业务标记也回滚。
  7. 多用户第 N 个失败：前 N-1 的已提交记录不消失，失败用户无 feed，重试前用户不重复。
  8. Speaker 同用户两腿只一条 feed；不同 type 不错误折叠。
  9. 27 型表驱动投影测试使用实际危险输入：raw provider response、auth header、cookie、验证码、重置字段、渠道原始对象；DB/API/cache 中均没有这些字段或值。核销码值不能出现在正文。
  10. deep-link 输入外部 URL、编码 scheme、claim/token/returnUrl、非法 UUID 不可进入可执行链接。
  11. 已 sent/failed delivery 重唤仍零新 channel jobs；过期旧接受时间不变成现在，不从存量 outbox 回填。
- **Verification：** 跑既有 outbox/worker/Consent 回归；新增断言做变异红/还原绿。只验证行为，不写 registry 源码文本/转发 mock echo 测试。

### U3. Server-first Client and Two My Surfaces

- **Dependencies：** U1、U2，先 SDL/codegen 再消费者。
- **Goal / Requirements：** R10–R13。
- **Files：**
  - 修改 `miniprogram/src/api/operations.ts`、`src/api/real.ts`、`src/domain/models.ts`、`src/state/accountState.ts`。
  - 生成 `miniprogram/src/api/generated/schema.ts`、`graphql.ts`。
  - 新建 `miniprogram/src/domain/notifications.ts`、`src/components/NotificationInbox/index.tsx`、`index.module.css`。
  - 修改 `miniprogram/src/pages/profile/index.tsx`、`src/pages/profile-lite/index.tsx` 及各自 `index.module.css`；旧通知样式若由共享 panel 替代则在同一改动删除，不清理其他区域。
  - 修改 `miniprogram/src/api/mockTransport.ts`，镜像 feed/read-mark 的行为，支持两账号、分页、错误，不保留 local append。
  - mockTransport 仅镜像后端真实收件人与既有通知类型；grantConsent 不生成 feed，审批操作也不能给操作者虚构「审批已完成」通知。
  - 更新 `miniprogram/tests/account-state.vitest.ts`；新建 `tests/notifications-domain.test.ts`、`tests/real-notifications.vitest.ts`。
  - 更新已有 `tests/real-auth.vitest.ts`、`real-content.vitest.ts`、`real-flashback-claim.vitest.ts`、`real-moderation.vitest.ts` 的 accountState mock imports，删除旧 append/readLocalNotifications 引用；不 re-pin 本机假通知测试。
- **Approach：** KTD7；删除 5 个本机 append 调用及其函数/导出，保留原操作 toast/成功反馈；这些回执不是通知业务，不在 backend 新增同类通知。
- **Test scenarios：**
  1. 返回服务端完整行映射与分页续读；成功空结果清缓存，分页错误不覆盖当前页。
  2. A 请求未完成时 activate B/clear/logout，晚到 A 响应和 mark-read 响应不显示、不写 B/no-account 缓存。
  3. 同一用户两次刷新逆序完成，只用最新结果；晚到 refresh 不回退服务端已读结果。
  4. network offline 同账号返回未过期缓存并显式 cache 状态；401/forbidden/契约错误拒绝 fallback。
  5. 缓存过期/坏格式/旧 local 格式不恢复；主动退出清当前账号缓存，pending scene 等原语义保持。
  6. mark 失败保留未读；重试成功读服务端 timestamp；新设备无缓存仍能读取已读状态。
  7. 分页去重与截止边界、恶意/本端未注册 deep-link 阻断；不新开 web-view 或平台导流。
- **Verification：** domain/transport 测试证明不确定边界；实际 UI 用微信 DevTools，不新增页面渲染测试框架。xhs/tt build 确认注册页限制未回退。

### U4. End-to-end Proof and Documentation

- **Dependencies：** U1–U3。
- **Goal / Requirements：** R13 和全套产品验收。
- **Files：**
  - 新建 `miniprogram/e2e/notification-inbox.e2e.mjs`，采用既有 E2E 执行与 CSS-module selector 约定，不另造 runner。
  - 更新 `miniprogram/e2e/journey.e2e.mjs`：删除依赖旧 local append 的 `/审批已完成/` 文案断言；新通知 E2E 改验真实收件人、feed ID 与 readAt 状态，不将该断言换成另一句 incidental wording。
  - 如需稳定锚点，更新现有 `miniprogram/e2e/anchors.mjs`，不用 data-testid。
  - 更新 `CONTEXT.md` 通知分发/通知类型段，新增收件箱与 Delivery 的语义区分。
  - 更新既有 `docs/运维/小程序订阅消息构建与真机验证.md`：站内接受记录、30 天与已读、Consent 独立、后端先部署和无历史回填。
  - 根 CHANGELOG 不由本任务直接改；交编排者协调 #985 后整合本期 backend/mp-wechat/mp-xhs 条目。
- **Test scenarios / Verification：** 完成下节真实 HTTP 与 GUI 脚本并保存脱敏摘要、截图；模拟错误及账号竞态，不以 mock 绿或截图有列表代替真实契约 proof。
- **Execution note：** 真实 smoke 通过后才更新现有文档；清除 throwaway seed/HTTP 客户端，保留能重跑的 E2E 和验收证据，不提交 dist/凭证/临时工件。

---

## Verification Contract

### Test-first and Mutation

批准实施后先写 consumer-visible 失败测试，再实现。迁移与生成文件不是用源码字符串测试确认。
新增权限、过期、幂等、配额、安全、账号竞态断言均做至少一个对应变异：

| 变异 | 必须变红的行为 |
| --- | --- |
| 移除 actor policy / 注入 authorize_if(always) | A 能读到 B 的已布置 victim 行，精确 ID 断言红；admin 不能旁路。 |
| read_at 改成普通当前时间覆盖 | 第二次/并发 mark 的首次 timestamp 不变断言红。 |
| feed 插到 Repo transaction 外 | 强制后续 Oban/外层回滚后 feed 零残留断言红。 |
| id 哈希加入 identity 或随机值 | 多身份/重试的一份记录断言红。 |
| read cutoff 去掉或 `<`/`<=` 互换 | 精确 cutoff 行不可见/可清理断言红。 |
| raw data 合入 payload / check_in_code 放正文 | 敏感 sentinel 不在 DB/HTTP 输出的断言红。 |
| 查询/append 错调 Consent.take | 已布置 quota 不变和零新增发送 job 断言红。 |
| 删除 epoch 校验 | Deferred Promise 的 A→B/logout 晚响应断言红。 |
| 接受任意 `/pages/` query | token/claim/外链参数导航拒绝断言红。 |

每次改坏仅在自己的 worktree；记录定向测试红输出、还原后绿输出；不得以空集合、没走分支或跳过用例蒙混。
事务故障通过本地测试作用域可回滚故障注入/受控 DB 约束触发，不加生产 fault hook。

### Future Commands

以下是批准后的执行命令，本轮未运行测试/构建/迁移。
所有 mix task 先 `mix help <task>` 读取当前选项；任务 worktree 隔离数据库，不共享主 checkout 的测试库。

| 工作目录 | 命令/用途 |
| --- | --- |
| 仓库 worktree 根 | `bash scripts/worktree/setup-worktree.sh`：一次性现有依赖/隔离开发库设置；不得读取或展示它使用的凭证文件内容。 |
| backend | `mix ecto.gen.migration create_notifications`；手写上/下迁移仅操作新表。 |
| backend | `mix ash_postgres.generate_migrations --snapshots-only`；后续 `--check`。 |
| backend | `mix absinthe.schema.sdl --schema Cgc2046Web.GraphqlSchema priv/graphql/schema.graphql`。 |
| backend | `mix test test/cgc_2046_web/graphql_notification_inbox_test.exs test/cgc_2046/notifications/inbox_test.exs test/cgc_2046/notifications/inbox_snapshot_test.exs test/cgc_2046/notifications/workers/notification_pruner_worker_test.exs`。 |
| backend | `mix test test/cgc_2046/notifications/delivery_test.exs test/cgc_2046/notifications/fanout_test.exs test/cgc_2046/notifications/workers/delivery_worker_test.exs test/cgc_2046/notifications/notification_worker_test.exs test/cgc_2046/notifications/notification_consent_test.exs test/cgc_2046/notifications/schedule_changed_subscriber_test.exs test/cgc_2046/events/qualification_test.exs`。 |
| backend | `mix test test/cgc_2046/identity_index_guard_test.exs test/cgc_2046/fk_on_delete_guard_test.exs`；所有改动 settled 后 `mix precommit`。 |
| miniprogram | `./node_modules/.bin/graphql-codegen-cjs --config codegen.yml`；SDL 与生成结果共同评审。 |
| miniprogram | `node --experimental-strip-types --test tests/notifications-domain.test.ts`。 |
| miniprogram | `./node_modules/.bin/vitest run tests/account-state.vitest.ts tests/real-notifications.vitest.ts tests/real-auth.vitest.ts tests/real-content.vitest.ts tests/real-flashback-claim.vitest.ts tests/real-moderation.vitest.ts`。 |
| miniprogram | `./node_modules/.bin/tsc --noEmit`；最终 `pnpm check:ci`，遵循子目录对 ERR_PNPM_IGNORED_BUILDS 的仓内二进制替代口径。 |
| miniprogram | `node e2e/notification-inbox.e2e.mjs`：拟新增可重跑入口，先按脚本固定 mock/real 两种验收用途，不将 fake transport 结果标为真实后端结果。 |

首次改导出接口前用可用 LSP 做 references，覆盖全部调用与 test imports，避免留下 appendLocalNotification/getNotifications 旧签名。
不反复跑无关全量检查；红绿/变异仅定向执行，完整 build/lint/test 在改动完成后集中运行。

### Real HTTP Smoke

ConnCase 有请求栈覆盖，但仍另启自己的实际 Phoenix endpoint 做 TCP HTTP，不能只跑 Absinthe.run。

1. 使用隔离 worktree dev DB；本地 fixture 创建 A/B、管理者、至少 23 条通知，同时间 tie、未读/已读/过期行及无 quota/多身份样本。
2. 先经既有业务动作/信号与改期、成班真实生产入口生成通知，再确认接受时刻可读；不用直接 insert feed 代替全部生产证明。边界时间夹具可直接通过内部资源受控创建。
3. 本地实际 `signIn` 请求取 session cookie，仅存在 throwaway Req 客户端内存；不开 shell trace，不打印 request headers/set-cookie、登录 response 或 credentials，不写 auth/token 文件。
4. A 的两独立 HTTP session 分页读取；session 1 mark，同 id session 2 mark，再读得到相同 readAt。B/admin 不能读或 mark A 的记录。
5. 不带认证、非法参数/filter/sort、恶意 cursor、过期 id 均验证准确拒绝结果；输出只记 HTTP 状态、error code、条目 ID 的本地别名、布尔断言。
6. provider 不实际发送真实通知；按本地测试 adapter/手动 Oban 模式确认入队与 feed 已有，不等渠道成功。验证 quota=0 接受记录存在，feed/read-mark 前后 quota/jobs 不变。
7. 执行 cleanup worker 后再次真实 HTTP 读取，过期行消失、新行保留；重复执行无变化。
8. 保存脱敏报告含实际命令、准确断言和时间边界，不包含用户/身份 UID、Authorization/cookie 或原始 provider body；随后清理 throwaway 账号/seed/client，不触碰生产数据。

验收脚本/endpoint 端口在实施时选择不与其他 worktree 的服务冲突；这是运行资源选择，不是产品配置。

### Mini Program GUI

Gate0 已仅做 readiness 查询：`wechatide` 可调用，skill 0.3.9，status versionRelation=equal、loginExpired=false、tokenRequired=false；未编译、未打开/操作任务小程序界面，未宣称 UI 验收。
实施时重新确认会话门禁（如已跨会话），读取 automator/debugger scene；不翻本地 token，授权窗口由用户处理。

**Mock GUI：** 使用现有 CGC_E2E_MOCK 构建与 mockTransport，覆盖可控的 loading、empty、首屏 error/retry、更多错误/retry、mark 失败/retry、恶意 link 不执行、A 请求延迟后 B/退出，截图须显示明确缓存/未读文本。
CSS selector 从实际产物 CSS-module 类名解析，不用 data-testid、不写死哈希。

**Real-backend GUI：** 使用自己的隔离本地 HTTP backend，构建指向该端点，不读取 .env 内容；在 weapp「我的」看到 U2 真实生成的报名结果/提醒/改期样本。
点击安全业务链接、返回、mark-read，再用另一个 HTTP session 修改已读，回到小程序刷新看到一致状态。
清理本机 notification cache 或使用新本地客户端会话后重新登录仍看到服务端 30 天内历史；退出/切换账号后无前账号通知。
离线时同账号缓存明确标识，恢复网络 retry 更新；401 不能显示缓存为已登录通知。
录屏/截图避免账号联系方式、身份 UID、凭证、模板 ID；以测试别名和 UI 状态留证。

**裁剪端：** xhs profile-lite 同一 panel 实际 surface 验收（既有 IDE 条件可用时）；至少三端 build/零导流检查及平台路由 domain 边界验证，tt 不新增 profile。
微信 GUI 是本功能必须完成的真实表面证据；不能用 web browser 截图或 mock GUI 代替真实 backend + weapp 组合。
屏幕阅读器/真机 accessibility 的人工验证若本地模拟器不可提供，应明确记录该视觉/辅助技术验证限制，不声称已经完成。

---

## Risks and Rollback

| 风险 | 决定/回退 |
| --- | --- |
| Inbox DB 故障会扩大接受事务的失败面 | 不允许 outbox 成功而 feed 失败的半状态；接受全部回滚，沿原 receipt/异常通道。不会新增无限重试；claim_first 的既有缺口需在交付报告明示。 |
| 无身份管理者被 managers 旧分组抹掉 | 只保留已命中角色 user，不放宽选择器；全体调用方需定向验证，特别 qualification 外层事务。 |
| 超过 30 天的纯站内来源重放 | 无永久墓碑；保留范围内严格去重，有 outbox 时利用原始接受时间抑制过期重建。只站内路径超窗不承诺永久去重，不能声称永久 exactly-once。 |
| 存量 outbox 没有 feed | 不回填、不导入旧 raw data；功能上线从新接受开始。重放不能被当成历史迁移。 |
| 新快照误带秘密 | 仅 title/body 白名单 builder，核销码不读入正文；DB+HTTP 的危险 sentinel 测试与变异一起验，不只检查列名。 |
| free-text 原因/安排可能含用户自行输入的敏感内容 | 仅复用业务本来展示给该用户的字段并限长，不存 raw payload；不承诺自动识别所有用户自行粘贴的秘密，不建立敏感信息扫描框架。 |
| Feed 行数增长、日清理峰值 | user/time/id 索引、first≤50、无 count、按日删除；本期不为假设规模新增分页清理调度框架。日清理失败由 Oban 既有作业错误暴露，读取 cutoff 仍生效。 |
| 新 operation 比生产 schema 先上线 | 后端先部署，再小程序上传/全量发布各执行既有 `pnpm check:release-schema`；不使用 runtime introspection 或 fail-soft query 绕过。所有生产步骤人工执行。 |
| #985 并行触及共享根文件 | 本期根 CHANGELOG 不改，auth/rate_limit/CI/web 不改；批准后自独立 worktree，按最新 develop 基线核对契约漂移。 |

**回滚顺序：** 已发布新小程序依赖新字段时，不能先移除后端 API；先人工回退小程序消费者并跑 release-schema 预检，再考虑后端代码回退。
仅 backend 未消费时，代码回退可暂留 additive 新表，既有投递链仍工作；不需删除用户数据。
后端 rollback 若留下已入队 NotificationPrunerWorker，而旧 release 没有该 module，会出现未知 worker；人工回滚前暂停/取消该类 maintenance job，不能修改其他队列。
Migration down 只 drop 新 notifications 表/索引，执行会不可逆丢失站内历史；必须人工批准，常规 rollback 不执行 down、不删旧 delivery/consent。
保留期清理后的正文无法恢复，本产品不提供恢复或归档入口。

**人工合并边界：** `backend/priv/repo/migrations/**` 在根授权表中为人工合并范围；本任务不得自合并，即便 CI 全绿。本轮所有 GitHub 写动作与发布动作均未授权。

---

## Definition of Done

- U1–U4 指定端到端行为全部成立；server feed 与 mark-read 契约、migration、snapshot、SDL、codegen 一起就绪。
- 27 个现有类型都有精确安全投影，身份扇出只一份 feed；direct Delivery 与 wish echo 不漏挂点。
- 30 天读取与清理边界、确定性分页、actor/恶意 OR、并发已读、quota 独立、事务回滚、账号切换均有 consumer-visible 红绿及变异证据。
- 删除本机假通知生产/旧签名/旧 tests/mock imports；不保留 shims，不将 Consent 操作回执伪装成新业务通知。
- 真实 HTTP 和真实 weapp GUI 报告可重跑；mock GUI 证据单独标记，不冒称 provider 送达或真机 accessibility。
- 现有文档说明接受与送达差异、claim_first 失败边界、保留期和回滚顺序；CHANGELOG 与 #985 的整合由编排者协调。
- 无新增依赖/服务/env knob，无凭证或原始敏感载荷，无 dist/throwaway 脚本、无生产修复/发布。
- 交独立 reviewer 审核后才讨论后续 commit/push/PR；migration 合并仍由人工执行。

本轮仅产出 Gate0 计划。上述实施验证均未执行；文档内部做范围/证据/依赖/失败行为一致性检查，不冒称独立交付评审已通过。
`ce-doc-review` 未运行：当前可用技能/调用机制没有该技能；由用户按其独立 reviewer 身份审本计划，不用另一个实现 agent 代替授权门。
