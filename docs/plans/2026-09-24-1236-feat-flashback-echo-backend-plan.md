---
title: "feat: 许愿树 Echo 后端一期（#834）"
date: 2026-09-24
type: feat
topic: flashback-echo
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: "GitHub #791 triage / #834"
execution: code
---

# feat: 许愿树 Echo 后端一期（#834）

## 计划状态

这是供 Owner 审批的实施计划，不是实现授权。由于本期涉及 Ash 资源、数据库迁移、GraphQL 契约与通知派发，Owner 明确批准前不开始 schema、migration 或业务代码改动。

## Goal Capsule

- **目标**：运营可对当前挂树、可见的愿望发布纯文本回响；公开树和成员长廊能读取回响；首次发布时按附议通知意愿与订阅余额派发通知，并直达对应愿望。
- **范围**：仅 #834 后端模型、状态机、admin GraphQL、三个读取面、通知入队与其验收。admin 页面、Web 展示、小程序展示分别由 #835、#836、#837 完成。
- **复杂度**：Ambitious。原因是同一个交付跨持久化状态机、公开字段白名单、并发下的一次性通知和三个客户端读取面。
- **非目标**：不创建 Event、不将回响关联真实活动、不通知愿望作者、不新增订阅授权表、不做机审、链接、筛选或更正历史版本。

## 当前证据

- GitHub #834 当前为 open、ready-for-agent，尚无实现 PR；#834 没有前置 issue。#835 还依赖 #817；#836、#837 依赖 #834。
- 基线 `develop` 为 `11b20079`。后端已有 `Wish`、`WishEndorsement`、公开树 `WishPublic` 以及 `flashback_wish_echo` 通知模板与渲染，但当前代码没有 Echo Ash resource、Echo 状态机、公开读字段或发送方。
- Echo 相关 GraphQL 由 `Cgc2046Web.GraphqlSchema` 手写；公开树读取在 `WishPublic`（原始 SQL 白名单），成员读取在 `Wishes`（Ash 查询），新增字段需两条读路都覆盖。
- `WishEndorsement.notify` 只表示用户意愿；通知服务在实际投递时调用 `Consent.take` 并在发送失败时退款。后端不得调用 `Consent.grant`。
- 维护者在 #791 的 2026-09-24 triage 拍板：纯文本 ≤500 字，统一署名「主办方」，只有挂树愿望能写回响，下架/撤回时公开回响隐藏，每个附议最多一次通知，通知机会在入队时消耗；更正与撤回不通知；作者不收通知；#791 保持 ready-for-human，四个子 issue 合入后由人做微信真机验收。

## 范围与契约

### 回响模型与状态机

- 新建 `Cgc2046.Flashback.WishEcho` Ash resource，并注册进 `Cgc2046.Flashback`；关联一个 `Wish`，记录正文、状态、创建/首次发布/最近更正/撤回时间，以及发布它的 admin 身份供审计。
- 正文在服务端 trim 后为 1–500 字纯文本；对外不解释或解析 HTML、链接。
- 合法状态：`draft → published → corrected`（可反复更正）；`published/corrected → revoked`；`revoked` 是终态。只能通过显式 domain actions 迁移，不能由通用 update 直接改状态。
- 只有 `visibility=public AND listed_at IS NOT NULL AND hidden_at IS NULL AND deleted_at IS NULL` 的愿望可以创建或发布回响。资格不符统一返回 `flashback_wish_not_found`，避免泄露愿望存在性。
- 愿望下架时，非 admin 读面隐藏该愿望的全部回响；重新挂树后恢复可见。软删除同样隐藏；硬删除级联清理 Echo 数据。

### GraphQL 契约

- admin 读写仅经 PlatformAdmin gate：`flashbackAdminWishEchoes(wishId)`、`flashbackAdminCreateWishEcho`、`flashbackAdminUpdateWishEchoDraft`、`flashbackAdminPublishWishEcho`、`flashbackAdminCorrectWishEcho`、`flashbackAdminRevokeWishEcho`。
- admin 查询可读 draft / revoked 和生命周期时间，同时返回符合 #834 定义的「当前可通知附议数」：`notify=true`、有 `user_id`、且尚未使用 Echo 通知机会。
- 三个非 admin 读面都提供 `latestEcho`、`echoCount`、`echoes`：公开树列表、公开树单条直达、成员面长廊胶囊愿望。`echoes` 仅包含 published/corrected，按首次发布时间正序；`latestEcho` 是其中发布时间最新者；空集合返回 `null / 0 / []`。
- 非 admin Echo 对象只返回 `id / content / status / publishedAt / correctedAt`。admin 身份、附议者账号与联系方式、draft、revoked 均不得进入非 admin payload。
- 保留公开树现有四条件过滤与字段白名单；成员面新增字段也必须检查 `hidden_at`，不可只依赖成员面当前愿望过滤。

### 一次性通知

- 首次发布某个 Echo 时，只为该愿望上 `notify=true`、有 `user_id`、且尚未使用机会的附议尝试入队；同一附议的后续 Echo 不再通知。Echo 更正或撤回不派发通知。
- 在附议上持久记录「Echo 通知机会已使用」；只有实际接受至少一个通知任务入队后才标记为已使用。订阅余额耗尽、用户最终未收到消息，仍按 #791 规则消耗该次机会；未找到平台身份或任务未成功入队时保留机会，留待之后的 Echo。
- 使用既有 `Notifications.Fanout`、`NotificationWorker`、`Notifications.Service` 与 `Consent.take`；不得依赖 Oban 7 天 unique 窗口充当永久去重，也不得新建授权表或从后端 grant 授权。
- 当前 `Fanout.deliver/5` 对零身份和内部入队异常都返回 `:ok`，不能单独证明任务已入队。实施时必须让本功能依据可验证的入队结果更新一次性标记，并用并发/失败测试证明「入队与标记」的一致性；不要把 `:ok` 当作入队收据。
- 微信落点从长廊首页改为带 `wishId` 的路径 `pages/flashback-corridor/index?wishId=<id>`。模板文案和槽位继续复用 `flashback_wish_echo`，固定引导不得暗示「愿望已实现」。

## 实施切片

1. **Ash model + migration**：建 Echo 表、状态/时间字段、admin 审计字段、Wish 关系；在附议上加 nullable 的一次性机会标记；同步手写 migration、Ash resource snapshot、删除级联。不要回填历史通知机会。
2. **Domain + admin GraphQL**：显式状态机 actions、愿望资格守卫、PlatformAdmin 鉴权、统一 not-found 错误；覆盖创建草稿、编辑、发布、更正、撤回和通知资格计数。
3. **三个非 admin 读面**：公开树列表/单条直达与成员面长廊加入一致的过滤、时间排序和白名单投影；批量装配回响，避免每条愿望单独查询。
4. **一次性派发**：首次发布在同一受控流程内选取符合条件的附议、取得入队结果、持久化一次性标记；保留 `Consent.take` 的现有余额消费与发送失败退款；通知携带正确 `wishId`。
5. **契约与验收**：GraphQL SDL 快照、`miniprogram` generated GraphQL types 同步；受影响 API 的成功/错误、授权、隐藏、通知和并发路径完成真实 GraphQL 验收。

## 先写失败清单与测试

在实现前把以下失败方式映射成 API 级测试，再写实现：

- 空白、超 500 字、未知状态、非法迁移、对 revoked 的任何修改/发布都被拒绝。
- 私密、未挂树、下架、删除的愿望不能创建/发布 Echo，错误形状统一且不泄露存在性。
- 非 PlatformAdmin 不能调用任何 admin Echo API；公开响应不含 admin id、联系方式、draft 或 revoked。
- 0/1/多 Echo、重复更正、撤回后的 `latestEcho / echoCount / echoes` 正确；公开树列表、单条直达、成员面读口径一致；下架隐藏且恢复后重现。
- 首次发布只为符合条件的附议成功入队；同时验证 `notify=false`、无 user id、无平台身份、授权余额耗尽、入队失败；后续 Echo 只覆盖机会尚未使用的新附议者。
- 并发首次发布、同一 Echo 重试、重复回调不得为同一附议重复创建已接受任务；更正/撤回不创建任务。
- notification worker 的 Consent.take/refund 行为不变；新路径只在微信支持的模板面生成正确 `wishId`，其他平台不能生成坏路径。
- 新 Echo 表与附议新增列在克隆 DB 上升级/回滚；无默认值回填；既有附议行默认机会未使用。若需给活跃附议表新增索引，采用并发建索引并单独验证。

**验证**：后端相关测试后再跑 `cd backend && mix precommit`；启动非生产服务，以真实 GraphQL query/mutation 走通成功与错误分支；生成并检查 SDL；运行 `cd miniprogram && pnpm codegen`，确认生成类型和提交契约一致。数据库迁移只在本 worktree 的克隆/隔离库验证，不读写生产库。SDL / codegen 变更纳入同一 issue 分支。

## 依赖、发布与权限

- #834 本身可独立实现；#835 等 #817 与 #834，#836/#837 等 #834。一个 issue 对应一个 LoopX agent Todo，不在本计划内代做子 issue UI。
- 计划获批后，在当前 issue 分支完成 #834；遇到人工合并范围 `backend/priv/repo/migrations/**`，PR 由人合入。公开 UI 子 issue 合入前不将这一批发布到 `main`。
- #791 是整批的人工验收 gate；#834、#835、#836、#837 均合入后，由人按 #791 执行真实微信订阅授权、通知送达、直达愿望、重复通知与更正/撤回验收。
- 无新增依赖。#824/#825 是与 #834 gate 无关的现有 workstream。

## Owner Gate

请 Owner 审批本计划后再开始 schema/migration 实施，重点确认：

1. 是否批准以上 #834 范围及「只在实际任务入队后消耗一次性机会；最终投递失败仍算已用」语义。
2. 若 `user_id` 存在但当前无可用平台身份，是否同意不标记为已用，让之后的 Echo 仍可尝试入队（本计划推荐此行为）。
3. 是否接受为满足入队收据而对现有 Fanout seam 做最小必要调整；不得以 7 天任务去重代替长期一次性标记。

在该 gate 被明确批准前，本 worktree 只包含计划文档，不修改产品代码、SDL 或 migration。
