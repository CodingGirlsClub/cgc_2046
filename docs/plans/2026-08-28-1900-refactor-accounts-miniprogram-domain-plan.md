# Accounts 改名 + Miniprogram 拆 Domain 实施计划

> 日期:2026-08-28 · 状态:待执行 · 规模:小(纯机械,~30 文件)
> 前置:ADR-0009 PR②-⑤ 已落地(feat/adr-0009-context-restructure,#338)
> 工作区:`.worktrees/adr-0009-context-restructure`(续用,或合 #338 后从 develop 新切)

## 调研结论

**可行性:高,纯编译期机械变更,零运行时行为变化(除 /ops/admin 分组)。**

### GlobalApi 触点全集(改名面)

| 类别 | 位置 | 数量 |
|---|---|---|
| domain 模块本体 | `lib/cgc_2046/global_api.ex`(含 admin 块、4 组 resource_group_labels) | 1 |
| 资源 domain 字段 | accounts/ ×12(User, Token, PhoneVerificationCode, WechatLoginTicket, UserIdentity, Workspace, WorkspaceMembership, MembershipRole, Role, PortfolioItem, WorkspaceProfile, JoinRequest, Invitation, WorkspaceApplication, AdminActionLog——实为 15,见下) | accounts/ 15 |
| 同上 | miniprogram/ ×3(Code, NotificationConsent, ShareScheme) | 3 |
| config | `config/config.exs:17` ash_domains | 1 |
| graphql_schema.ex | domains 列表 ×1;`admin_result(..., GlobalApi)` ×3;`map_error` ×1;`to_ash_graphql_errors` 默认参数 ×1(注释自称「历史调用方均属此域」) | 6 |
| Live/task | `platform_admin_live_auth.ex:62`、`mix/tasks/cgc2046/promote_admin.ex` ×2 | 3 |
| 注释引用 | `admission.ex:6`、`payments.ex:6`(KTD1「与 GlobalApi 同款」) | 2 |
| 测试 | `domains_test.exs` ×3、`accounts/workspace_test.exs` ×9(domain: 选项) | 2 文件 |
| web/miniprogram 前端 | **零引用**(SDL codegen,domain 名不进 SDL) | 0 |

### Miniprogram 拆分面

- 三资源均 `extensions: [AshAdmin.Resource]` + `resource_group(:miniprogram)`,**无 GraphQL 块** → 拆出后 SDL 零 diff。
- `Cgc2046.Miniprogram` 模块名空闲(现有的是目录命名空间 `Miniprogram.*` 与无关的 `Cgc2046.MiniprogramCode`),可建 domain 模块。
- `Cgc2046.Accounts` 模块名同样空闲(只有 `Accounts.*` 子模块)。

### 关键决策

- **D1** 改名目标:`Cgc2046.GlobalApi` → `Cgc2046.Accounts`,文件 `global_api.ex` → `accounts.ex`。
- **D2** Miniprogram domain = `Cgc2046.Miniprogram`(`lib/cgc_2046/miniprogram.ex`),收编 Code / NotificationConsent / ShareScheme 三资源。**UserIdentity 留 Accounts**(namespace 在 Accounts 下,概念是用户身份绑定而非小程序运营资源)。
- **D3** Miniprogram domain **不进 graphql_schema domains**(无 GraphQL 资源,与 Mcp 同款),只进 `config.exs` ash_domains;带 `AshAdmin.Domain` extension + admin 块(`show? true`、`name("Miniprogram")`、`resource_group_labels(miniprogram: "小程序")`),保 /ops/admin 可见性。Accounts 的 admin 块删 `miniprogram` 组 label,`name("Accounts & Tenancy")` 保留。
- **D4** `to_ash_graphql_errors` 默认参数 `domain \\ Cgc2046.GlobalApi` → `Cgc2046.Accounts`,注释同步。
- **D5** AshAuthentication 无独立 domain 配置(策略随 User/Token 资源内声明),随迁即过;sign-in 测试是验证网。

## 实施步骤(单 PR,两 commit)

### Commit 1:Miniprogram domain 拆分

1. 新建 `lib/cgc_2046/miniprogram.ex`:`use Ash.Domain, extensions: [AshAdmin.Domain]`,admin 块按 D3;resources 注册三资源。
2. 三资源 `domain: Cgc2046.GlobalApi` → `Cgc2046.Miniprogram`。
3. `global_api.ex`:resources 删三行;admin 块删 `miniprogram` label。
4. `config/config.exs`:`Cgc2046.Miniprogram` 插入 ash_domains(字母序,Learning 与 Payments 之间)。
5. `domains_test.exs`:全集断言从 `@bounded_context_domains ++ [GlobalApi, Mcp, Payments]` 加 `Miniprogram`。

### Commit 2:GlobalApi → Accounts 改名

6. `git mv lib/cgc_2046/global_api.ex lib/cgc_2046/accounts.ex`,模块名 `Cgc2046.Accounts`。
7. 15 个 accounts 资源 `domain:` 字段随迁(机械替换)。
8. `config.exs`、`graphql_schema.ex` 6 处(D4 含默认参数)、`platform_admin_live_auth.ex`、`promote_admin.ex` ×2。
9. 注释清偿:`admission.ex`、`payments.ex` 的 KTD1 引用改 `Cgc2046.Accounts`;`to_ash_graphql_errors` 注释「历史调用方均属此域」措辞保留、域名换。
10. 测试随迁:`workspace_test.exs` ×9、`domains_test.exs` ×3(含「GlobalApi」字面断言改「Accounts」)。
11. CONTEXT.md:领域列表词条把 `Accounts(GlobalApi)` 归一为 Accounts;GlobalApi 从 atom 清单删。

## 门禁(沿用 ADR-0009 纪律)

- `mix compile --warnings-as-errors` 零警告
- `mix test` 全绿(重点:accounts/workspace_test、domains_test、sign-in 相关)
- SDL 排序归一化**零 diff**(Miniprogram 无 GraphQL 面;domain 名不进 SDL)
- `grep -rn GlobalApi backend/` 零残留(含注释)
- `mix ash_postgres.generate_migrations --check` clean(domain 改动不触 schema)
- /ops/admin 烟测:Accounts & Tenancy 与 Miniprogram 两 section 渲染,三资源在 Miniprogram 组下可见
- web/miniprogram 目录零 diff

## 评审口径

机械搬迁同形模板(与 PR②④ 同):`review=skipped`,门禁全确定性。若门禁全过无须 ce-code-review;任一门禁意外翻红再升级评审。

## 风险

- **唯一行为面:/ops/admin 分组变化**(ops 内部工具,低风险,烟测覆盖)。
- AshAuthentication 签入链路:domain 随迁后由 sign-in 测试验证,无独立配置点。
- 无 DB 迁移、无 SDL 变化、无前端影响。
