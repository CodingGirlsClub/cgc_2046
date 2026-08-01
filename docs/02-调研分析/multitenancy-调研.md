# CGC 平台多租户方案调研

> 日期:2026-07-31
> 目的:基于现有技术栈(Phoenix + Ash 3.31 + AshPostgres 2.11 + AshAuthentication 4.14),调研多租户实现方案与社区最佳实践,为后续领域模型定基础。
> 状态:调研完成,**决策点 1–5 全部已确认**,多租户地基定稿

---

## 1. 背景

CGC 平台将采用多租户架构:每个 Club/分会(CGC 北京、CGC 深圳、CGC 北京的某书店)是一个独立的 **Workspace(租户)**。租户内有多角色成员(组织者/教练/志愿者/学员)、Workflow、Agent(个人+公共),以及可插拔的 Event/Course 插件。

多租户是地基,它决定了角色、Workflow、Agent 等所有权限模型的复杂度。

---

## 2. Ash 原生多租户支持(官方两种策略)

### 2.1 attribute 策略(共享表 + tenant_id 列)

所有租户共用同一张表,通过一个属性(如 `organization_id`)区分:

```elixir
multitenancy do
  strategy :attribute
  attribute :organization_id
end
```

要点:
- **强制隔离**:不指定 tenant 直接报错,防止"忘了过滤"
- 查询自动加 `organization_id == X`,创建自动写入
- `global? true` 可允许无租户查询(需配 policy 防护)
- `parse_attribute` / `tenant_from_attribute` 可转换租户值(如 `"org_10"` ↔ `10`)
- **唯一性约束自动 tenant-aware**(同一租户内唯一,跨租户可重复)
- 外键自动变复合外键(带 tenant_id),跨租户引用被数据库层拦截

### 2.2 context / schema 策略(Postgres schema per tenant)

AshPostgres 用 Postgres schema 实现,每个租户一个独立 schema(如 `org_10`):

```elixir
postgres do
  manage_tenant do
    template ["org_", :id]
  end
end
```

要点:
- 创建租户时自动 `CREATE SCHEMA org_10` + 跑迁移
- **迁移要跑两套**:公共 `priv/repo/migrations` + 每租户 `priv/repo/tenant_migrations`
- Repo 需实现 `all_tenants/0` 回调,返回所有需迁移的 schema
- 好处:物理隔离、授权逻辑简化、单租户数据删除容易、查询性能好(小表)
- 代价:迁移×N 管理、schema 数量上限、备份恢复复杂

---

## 3. 社区最佳实践(三种模式对比)

| 维度 | A. 共享表 + tenant_id | B. 共享库 + 每租户 schema | C. 每租户独立库 |
|---|---|---|---|
| 隔离强度 | 弱(靠应用层过滤) | 中(物理隔离) | 强 |
| 开发/迁移成本 | 最低(一套迁移) | 高(迁移×N) | 最高 |
| 运维成本 | 低 | 中 | 高 |
| 数据泄漏风险 | 高(漏过滤即泄漏) | 低 | 最低 |
| 租户数伸缩 | 无限 | 受 schema 数量限制 | 受连接数限制 |
| 单租户数据导出/删除 | 难 | 容易 | 容易 |
| 性能 | 大表共享(有 noisy neighbor) | 每租户小表 | 每租户独立 |
| 典型适用 | 起步 SaaS、租户多数据小 | 中规模、需一定隔离 | 大客户、合规(数据驻留) |

**社区明确的警告(Bytebase 等)**:
- 模式 B(每租户 schema)**复杂度接近独立库,隔离又不如独立库**,除非有合规要求,否则不建议
- 模式 A 的**安全加固手段是 Postgres RLS(行级安全)**:在数据库层强制隔离,防止应用层漏过滤

### RLS 加固(模式 A 的补丁)

```sql
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE projects FORCE ROW LEVEL SECURITY;  -- 关键:owner 也强制
CREATE POLICY tenant_isolation ON projects
  FOR ALL USING (tenant_id = current_setting('app.tenant_id')::uuid);
```

应用层在事务内设置 `app.tenant_id`,数据库层兜底隔离。代价:每个查询多一层策略执行,调试更复杂。

---

## 4. 与认证(ash_authentication)的集成要点

官方文档明确:
- 若 User/Token 资源是多租户的,`Ash.PlugHelpers.set_tenant/2` **必须在认证 plug 之前**执行,否则认证查询拿不到租户

社区推荐的模式(Elixir Forum 讨论,与我们场景吻合):

```
Organization/Workspace  (全局,租户注册表)
Identity               (全局,账号身份)
User                   (租户,每个 Workspace 一个用户记录)
Token                  (全局,认证令牌)
```

即:**认证身份全局,业务数据按租户**。一个自然人账号可属于多个 Workspace,各租户内有独立的 User/成员记录。

Ash 侧配套:
- `Ash.PlugHelpers.set_tenant/2` — plug 管道中按请求设置租户
- `Ash.Scope` — 把 actor + tenant + context 打包传递

---

## 5. 映射到 CGC 平台

### 5.1 哪些资源全局(平台层,无租户)

| 资源 | 说明 |
|---|---|
| **User**(账号) | 一个自然人一个账号,可加入多个 Workspace |
| **Workspace** | 租户本身(注册表,含 slug/名称/品牌) |
| **Identity / Token** | 认证凭据 |

### 5.2 哪些资源按租户隔离(workspace_id)

| 资源 | 说明 |
|---|---|
| **WorkspaceMembership**(成员资格) | 用户↔Workspace 关联 + 角色 |
| **Role** | 租户内角色(Owner/Admin/Tutor/Volunteer/Learner…) |
| **Workflow** | 租户内工作流 |
| **Agent** | 个人 Agent(绑定成员)+ 公共 Agent(空间级) |
| **Event / Course** | 插件数据,租户内 |
| **Portfolio** | 学员作品 |

### 5.3 租户数据流

```
请求 → 解析租户(slug/子域名/登录后选择)
     → Ash.PlugHelpers.set_tenant(workspace)
     → 认证/授权 → 按租户读数据
```

---

## 6. 推荐方案

### 推荐:模式 A(共享表 + tenant_id)+ Ash attribute 策略

理由(结合我们的具体场景):

1. **租户数量级**:CGC 分会是几十到几百的量级,每个租户数据量小(几十~几百人)——这是模式 A 的理想区间,不是大客户 SaaS
2. **开发速度**:一套迁移、一套 schema,不需要管理 tenant_migrations 双目录,不阻塞后续领域模型开发
3. **Ash 强制隔离**:attribute 策略下不指定租户直接报错,天然防漏过滤
4. **唯一性 tenant-aware**:同一租户内角色名/Workflow 名唯一,跨租户不冲突
5. **外键复合保护**:跨租户引用被数据库层拦截
6. **升级路径**:未来若有大分会要求独立导出/合规,可迁移到模式 B(Ash 有完整工具链),但要评估成本

### 起步阶段不做(降低复杂度)

- ❌ 模式 B(每租户 schema):迁移×2 管理,社区明确不建议
- ❌ 模式 C(每租户独立库):完全不需要
- ❌ RLS 纵深防御:Ash policy + 强制 tenant 已足够,RLS 增加调试复杂度;等有真实安全审计需求再补

### 与认证的组合

- User/Identity/Token 资源:**不做多租户**(全局账号,一人多 Club)
- WorkspaceMembership/Workflow/Agent 等:**attribute 策略**
- 登录后携带 tenant:前端登录时选择/携带 Workspace slug,后端 plug 设置

---

## 7. 待用户拍板的决策点

1. **隔离级别**:✅ **已确认** — 共享表 + tenant_id(方案 A),不走 schema-per-tenant
2. **账号模型**:✅ **已确认** — 一个自然人账号可加入多个 Workspace(全局账号),不按租户注册
3. **租户解析方式**:✅ **已确认** — 起步做"邀请链接 + 登录后工作台选择";子域名(beijing.cgc.dev)二期再考虑,但 slug 设计提前预留
4. **租户标识**:✅ **已确认** — UUID 主键 + slug 展示(`beijing`);slug 全局唯一
5. **全局资源范围**:✅ **已确认** — User/Workspace/Identity 全局,其余(WorkspaceMembership/Role/Workflow/Agent/Event/Course/Portfolio)按租户

### 邀请链接格式(决策点 3/4 补充)

- 格式:`slug + UUID 末 4 位`,如 `beijing-3f9a`——短、好记、可复制
- **不暴露完整 UUID**,降低枚举/猜测风险
- 服务端按 `slug + 末4位` 反查 Workspace 校验,失败即无效链接

---

## 8. 参考来源

- Ash 官方 Multitenancy 文档:https://ash.hexdocs.pm/multitenancy.html
- AshPostgres Schema Based Multitenancy:https://ash-postgres.hexdocs.pm/schema-based-multitenancy.html
- Bytebase《Multi-Tenant Database Architecture Patterns Explained》:https://www.bytebase.com/blog/multi-tenant-database-architecture-patterns-explained/
- Iurii Rogulia《Shared Schema vs Schema-per-Tenant》(RLS 实践):https://iurii.rogulia.fi/blog/multi-tenant-saas-schema
- Elixir Forum《AshAuthentication with multi-tenancy》:https://forum.elixirforum.com/t/ashauthentication-with-multi-tenancy-and-api-keys-strategy/71507
