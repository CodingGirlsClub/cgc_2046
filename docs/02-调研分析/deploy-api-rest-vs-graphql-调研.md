# deploy API:REST vs GraphQL(决策调研)

> 调研日期:2026-07-31 · 来源:OpenClacky 官方文档(extend-api / extend-host-api)、AshGraphql 1.10、Apollo Client 4、ash_authentication 4.14.1(见 ash-authentication-token-调研.md)
> 回答的问题:OpenClacky 扩展(cgc-bridge)把 Workflow 部署到 CGC 平台,接口走 **REST 端点**还是 **GraphQL mutation**?

---

## 一、结论(推荐)

**平台内部 API 双轨制,部署接口走 REST 端点,网站前端走 GraphQL。**

- **OpenClacky 侧(cgc-bridge)→ 平台:REST 端点**(`POST /api/v1/workflows` 等,JSON + Bearer token)
- **网站前端(Next.js + Apollo 4)→ 平台:GraphQL**(保持不变,业务查询/变更)
- **后端:一个 Ash action,两个传输壳**——REST controller 与 GraphQL mutation 都只是薄壳,调用同一个 Ash action

**关键依据(为什么这不削弱安全)**:严格授权链(RBAC 判定、Step 授权、多租户隔离)应建在 **Ash 资源 policies 层**(`policies do ... end` + 自定义 Check),认证在 **Phoenix plug 层**。REST 与 GraphQL 都只是传输层——**两条入口共享同一套认证 + 授权判定**,选 REST 不产生任何安全绕过面。

## 二、证据与考量

### 2.1 OpenClacky 扩展客户端是 Ruby,天然偏好 REST

来自 OpenClacky 官方文档(extend-api / extend-host-api):

- 扩展 API handler 是 **Ruby DSL**:`class CgcBridge < Clacky::ApiExtension`,`get/post/put/patch/delete` 声明式定义端点;上下文提供 `json()/error!()/json_body()` 等。
- 调用外部服务用标准 HTTP(Net::HTTP 或任一 Ruby 客户端)——**JSON body + Authorization header 是 Ruby 侧最自然、最易调试的形态**(我们的 cgc-bridge `forward/3` 已按此设计)。
- 若改 GraphQL:handler 里要**手工拼 query/mutation 字符串 + variables**,易错、难调试、无类型提示;OpenClacky 侧没有 Apollo 类客户端(本地 Ruby 运行时)。

**一句话:部署接口的唯一调用方是 Ruby 扩展,REST 是它的母语。**

### 2.2 平台前端已定 GraphQL,不冲突

- 网站(Next.js 16 + Apollo Client 4.2.9)读 Workflow/AgentRun、用户旅程,走 **GraphQL**(技术调研已定)——这是**面向浏览器的客户端**。
- 但 OpenClacky 不是浏览器:它不经过网站前端,直接打平台 API。**GraphQL 的"统一入口"价值针对的是前端生态,不强制外部机器客户端也用 GraphQL。**

### 2.3 安全层在两壳之下(重点)

- **认证**:`load_from_bearer`(ash_authentication plug)挂到 `/api/*` 与 `/api/graphql` 两个管道——Bearer token 两边同样校验(白名单模式详见 ash-authentication-token-调研.md)。
- **授权**:Ash action 执行时由 **Ash.Policy.Authorizer + 自研 Rbac Check** 判定(角色 × 操作 × 资源 × Step.allowed_roles);REST controller 与 GraphQL mutation 都只是"把参数传给 Ash action"的薄壳,**不各自实现鉴权**。
- **多租户**:Ash 多租户上下文(set_tenant)在 action 执行前设置,两壳一致。
- 因此:**REST vs GraphQL 不改变任何安全边界**。真正的安全工作在 plug + Ash policies,与传输层解耦。

### 2.4 REST 的附加便利

- **curl 冒烟测试**:P0 联调(本地 OpenClacky → 平台)用 curl 直接打 REST 端点,和 OpenClacky 扩展的真实行为一致;GraphQL 要带 query 包装。
- **幂等/错误语义**:REST 用 HTTP 状态码(201/401/403/409/422)直白映射 OpenClacky 侧 `error!(...， status:)`;GraphQL 错误在响应体里,handler 解析更绕。
- **审计中间件**:`/api/v1/*` 管道可统一挂审计 plug,记录 actor/client/action/resource(OpenClacky 文档 §3.5);GraphQL 单端点则需在 mutation 层逐条埋点。

### 2.5 反方论据(为什么"全 GraphQL"也成立,但我们不选)

- "平台 API 统一走 GraphQL"能让 schema 单一、类型自文档化。
- 但代价:Ruby handler 拼 GraphQL 字符串、调试困难、curl 冒烟失真;且 AshGraphql mutation 的安全同样依赖 policies——**统一性收益是文档层面,不是安全层面**。两壳共享一个 action 时,"双轨"的实际重复代码只有两个薄壳函数,几乎为零。

## 三、落地形态(写进 spec)

```
后端
├── /api/v1/*                      ← REST(OpenClacky cgc-bridge 调用)
│   ├── POST /api/v1/workflows        部署 Workflow(幂等:name+workspace 更新)
│   ├── POST /api/v1/agents           创建个人 Agent
│   ├── GET  /api/v1/me               查询 token 身份与权限(渲染"我能做什么")
│   └── pipe: :bearer_users + 审计 plug
├── /api/graphql                   ← GraphQL(网站前端,不变)
│   └── AshGraphql mutation/query  → 同一批 Ash action
└── Ash 资源层(共享安全边界)
    ├── Ash.Policy.Authorizer + 自研 Rbac Check
    ├── ApiToken 白名单校验(require_token_presence)
    └── set_tenant(workspace)
```

- **幂等**:Workflow 以 `workspace_id + name` 为业务键,存在则更新(与 OpenClacky 文档 §4 P1.2 一致)。
- **错误契约**:401 认证失败 / 403 越权 / 409 冲突 / 422 DSL 校验失败,body 为 `{"error": "..."}`——OpenClacky handler 直接透传。

## 四、影响范围

| 环节 | 影响 |
|---|---|
| OpenClacky cgc-bridge(handler.rb) | `forward(:post, "/api/v1/workflows", body)`——已按此写,无需改动 |
| 后端 P1(TDD) | 新增 REST controller 测试骨架(REST 优先于 GraphQL mutation 测试) |
| 后端 M0 管道 | `/api/v1` 管道挂 bearer + 审计;`/api/graphql` 管道挂 bearer |
| 网站 | 无影响(GraphQL 不变) |
