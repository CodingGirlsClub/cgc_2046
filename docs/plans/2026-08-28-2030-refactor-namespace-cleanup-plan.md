# 命名空间清偿实施计划(Notifications / Integrations / Policies)

> 日期:2026-08-28 · 状态:待执行 · 规模:中(纯搬迁,~25 模块改名)
> 前置:ADR-0009 全序列 + Accounts 改名/Miniprogram 拆域已落地(worktree feat/adr-0009-context-restructure)
> 工作区:`.worktrees/adr-0009-context-restructure` · 形态:**单 PR,三 commit**
> 纪律:SDL 排序归一化零 diff;不动 worker 模块(Oban 在途任务风险,item 4 已明确缓行)

## 调研定案(2026-08-28 实测)

- 根部流浪模块 13 个,本计划清其中 9 个(notification ×4、miniprogram_code、oauth/sms/swoosh 渠道 ×3、rbac);`approval_claim/approval_deadline/offering/pending_approvals/release/mailer/repo/application` 为 shared kernel 或应用基座,不动。
- `Payments.NotificationTemplates` **留 Payments 不动**:实测调用方全部为支付流(payment_refund/expiry/settlement worker + notification_worker + 测试),文案归属支付上下文,Notifications 只做投递编排。
- Oban cron(config.exs:169-184)以模块 atom 引用 workers——**本轮不动任何 worker 模块**,cron 零影响。
- 名字冲突注意:根部 `Cgc2046.NotificationConsent`(服务)与 `Cgc2046.Miniprogram.NotificationConsent`(资源)同名异义,迁移时 leaf 改名须防误伤(见 D2 工具策略)。

## 决策

- **D1 Notifications 命名空间**:`Cgc2046.Notifications.{Fanout, Service, Subscriber, Consent}`(目录 `notifications/`)。模块内名去 Notification 前缀(命名空间已表达)。
- **D2 改名工具**:首选 LSP rename(workspace 级,跟随 alias/短引用);fallback = ast_edit 双模式(全限定路径 + leaf alias 节点),leaf 模式遇 `NotificationConsent` 冲突时逐文件核对 proposal 再 resolve。**门禁以 compile + grep 零残留为准**。
- **D3 Integrations 渠道层**:`Cgc2046.Integrations.Wechat.{Client, Requester, UrlScheme, WebOAuth}` + `Cgc2046.Integrations.SendCloud.{Sms, Mailer}`。
  - `Miniprogram.Client`(msgSecCheck 等微信 API)→ `Integrations.Wechat.Client`
  - `Miniprogram.WechatRequester`(HTTP 宿主)→ `Integrations.Wechat.Requester`
  - `Miniprogram.UrlScheme`(create_link 渠道调用)→ `Integrations.Wechat.UrlScheme`
  - `OAuth.WechatWeb`(网页扫码登录)→ `Integrations.Wechat.WebOAuth`
  - `Sms.SendCloud` → `Integrations.SendCloud.Sms`;`SwooshAdapters.SendCloud` → `Integrations.SendCloud.Mailer`(**config.exs 的 Mailer adapter 引用随迁**)
  - `miniprogram/` 目录只留 domain 资源与领域服务;`Cgc2046.Mailer`(Swoosh 应用基座)留根部。
- **D4 MiniprogramCode 归 Accounts**:实测为「Workspace Invitation → 平台小程序码」服务(Ash 查询 Invitation/Role + 配额 UPSERT + 平台外呼),数据绑定邀请生命周期 → `Cgc2046.Accounts.MiniprogramCode`(3 处引用随迁)。
- **D5 ShareSchemeService 留 Miniprogram**:ShareScheme 资源的领域服务(生成/复用编排),经 `Integrations.Wechat.UrlScheme` 外呼——领域服务 + 渠道客户端分层,不搬。
- **D6 Policies 就近归队**(14 个 check):
  - → `Cgc2046.Accounts.Policies.*`(10):platform_admin、platform_admin_owner_invite、own_user、read_own_user、own_workspace_profile、read_workspace_profile_by_visibility、workspace_actor_is_owner_or_admin、workspace_actor_is_volunteer、actor_is_workspace_member、actor_is_workspace_member_via
  - → `Cgc2046.Admission.Policies.ActorIsEnrolledLearner`(1)
  - → `Cgc2046.Sponsorship.Policies.*`(2):sponsorship_approver、sponsorship_delivery_readable
  - → `Cgc2046.Offering.ActorReadsOffering`(1,offering seam 同目录,不单立 policies 层)
- **D7 Rbac 归 Accounts**:`Cgc2046.Rbac` → `Cgc2046.Accounts.Rbac`(10 处引用;workspace 成员能力单源,概念属 Accounts/Tenancy)。
- **D8 各域不再保留 policies/ 袋**:`lib/cgc_2046/policies/` 目录清空删除。

## 步骤(三 commit)

### Commit 1:Notifications 上下文收拢
1. `notification_fanout/notification_service/notification_subscriber/notification_consent.ex` 移入 `notifications/`,模块改 `Cgc2046.Notifications.{Fanout,Service,Subscriber,Consent}`(D2 工具)。
2. 引用随迁(实测外部引用:Fanout 8 / Service 2 / Subscriber 4;Consent 计 grep 实测)。
3. CONTEXT.md 引用同步(NotificationFanout/Service 词条,§467 收敛边界条目)。

### Commit 2:Integrations 渠道层
4. D3 六项搬迁 + `MiniprogramCode` → Accounts(D4)。
5. config.exs Mailer adapter 引用随迁;CONTEXT.md 渠道词条同步(§403 content_check、§450/451 ShareScheme 架构位置)。

### Commit 3:Policies 归队 + Rbac
6. D6 十四 check 搬迁(资源 policies 块内引用随迁)、D7 Rbac、D8 删空目录。
7. CONTEXT.md 相关词条同步(Rbac 单源词条、policies 引用)。

## 门禁(每 commit 全过)

- `mix compile --warnings-as-errors` 零警告(改名漏网在此现形)
- `mix test` 全绿(基线 1602;含 policies 生效的授权测试与通知流测试)
- SDL 排序归一化**零 diff**(无 GraphQL 面变更)
- `grep -rn "NotificationFanout\|NotificationService\|NotificationSubscriber\|Cgc2046.NotificationConsent\|Miniprogram.Client\|WechatRequester\|Miniprogram.UrlScheme\|OAuth.WechatWeb\|SwooshAdapters\|Sms.SendCloud\|Cgc2046.MiniprogramCode\|Cgc2046.Policies\.\|Cgc2046.Rbac\b" lib/ test/ config/` 零残留(注释除外,注释须人工过一遍)
- `mix ash_postgres.generate_migrations --check` clean
- web/miniprogram 目录零 diff

## 评审口径

机械搬迁同形模板(PR②④ 同款):`review=skipped`,门禁全确定性;任一门禁意外翻红升级 ce-code-review。

## 风险

| 风险 | 缓解 |
|---|---|
| leaf 改名误伤同名模块(NotificationConsent 根服务 vs Miniprogram 资源) | D2:proposal 逐文件核对;compile + grep 双门 |
| Swoosh adapter 改名漏 config → 邮件发送运行时崩 | config.exs adapter 引用列入门禁 grep;通知/邮件测试覆盖 |
| Oban 在途任务 | 本轮零 worker 改名,无风险 |
| CONTEXT.md 词条漂移 | 每 commit 含文档同步步骤,grep 门禁兜底 |
