# ADR-0013：MCP OAuth 授权服务器（OAuth 成为默认连接路径）

- 状态：**已接受**；真机端到端验收待完成（替身授权服务器的 CLI 通道已实测，见 `docs/plans/2026-09-15-u2-host-spike-report.md`；Desktop 点击授权、Windows 走查计入计划的人工验收矩阵）。
- 日期：2026-09-15
- 关联：ADR-0001（BYO 架构：D3/D5/D6/D9/D12/D13/D14）、ADR-0002 D-A7（扩展自动配置 mcp.json）、计划 `docs/plans/2026-09-15-0016-feat-opencode-desktop-host-plan.md`（KTD1/KTD2/KTD3/KTD8）、宿主行为实测 `docs/plans/2026-09-15-u2-host-spike-report.md`
- 承接关系：**部分取代 ADR-0001 的 D13**（见 §5）；对 ADR-0001 D6 是扩展而非推翻。

---

## 1. 背景（Context）

1. **平台侧的接入面只有一条开发者路。** ADR-0001 确定的 BYO 形态（用户自带宿主 + 平台只做 MCP server）已经跑通，但连接方式只有静态连接 token：用户要自己签发令牌、粘贴进宿主的配置文件。这面向开发者成立，面向非编程用户不成立——他们不打开终端、不编辑配置文件。
2. **宿主生态已有标准答案。** MCP 授权规范（2026-07-28）要求资源服务器支持受保护资源元数据（PRM，RFC 9728）并在未授权时给出发现指引；客户端走动态客户端注册（DCR）或预注册 client、授权码 + PKCE、loopback 回调。opencode 1.18.30 的行为已逐项实测（U2 ②③）：无令牌调用 → 401 → 取 PRM → 取授权服务器元数据 → DCR → 浏览器授权 → 回调 `127.0.0.1:19876` → 换令牌；刷新被拒返回 `invalid_grant` 时宿主清凭证并转入「需要授权」。
3. **域与 cookie 的硬约束。** 授权确认页必须读用户在主域（web 站点）的 host-only 登录 cookie，否则用户要在一个不相干的域重新登录；而 RFC 8414 要求授权服务器元数据与其 `issuer` 同源。因此协议面的一部分**必须**落在 web 域，而 MCP 资源与 PRM 必须留在 api 域（宿主配置的 `mcp.url` 不能变，否则破坏既有接入）。
4. **安全面必须真做。** 新增的是匿名可达的写端点（注册）与浏览器跳转流（授权、回调），以及一种新的长期凭证（刷新令牌）。自建授权服务器要自行承担 PKCE 校验、轮换与重用检测、撤销级联、元数据一致性等全部安全面。
5. **实时撤销是产品承诺，不是可选项。** 用户在 web 撤销授权后必须立刻生效；而 access token 是自包含 JWT，纯签名校验做不到即时失效（只撤销 access 会被宿主静默 refresh 绕过，U2 ③ 实测）。

---

## 2. 决策（Decision）

> 与 ADR-0002 的 D-A 系列同类，本 ADR 用 D-B 编号（D-B1–D-B10）。

| # | 决策 | 代码/配置落点 |
|---|---|---|
| D-B1 | 认证面改为**双凭证**：OAuth 凭证为主路径，静态连接 token 保留为兼容路径。二者形状可分（access token 是 JWT，静态 token 不含 `.`），解析后都落到工具层同一个用户契约 | `backend/lib/cgc_2046_web/plugs/mcp_auth_plug.ex` |
| D-B2 | 授权服务器采用 `ash_authentication_oauth2_server` 0.3.1，auth 栈升至 `ash_authentication` 5.0.0-rc.13 / `ash_authentication_phoenix` 3.0.0-rc.10 | `backend/mix.exs`、`backend/mix.lock`、`backend/lib/cgc_2046/oauth2_server.ex` |
| D-B3 | `issuer` = **web 站点域**（裸域，显式配置，不由请求 host 推导）；`resource` = **api 域 MCP 端点**（与宿主 `mcp.url` 同值）。两个值由单点配置供给 | `backend/config/runtime.exs`（`OAUTH2_ISSUER_URL` / `OAUTH2_RESOURCE_URL`）、`backend/config/deploy.yml`（env.clear） |
| D-B4 | 协议端点与授权页在 web 域（`{issuer}/oauth/{authorize,token,revoke,register}`、`{issuer}/.well-known/oauth-authorization-server`）；PRM 与 MCP 在 api 域（`{resource origin}/.well-known/oauth-protected-resource`、`/mcp`）。web 域暴露由**部署层路径路由**承载，不经前端中间件 | `backend/lib/cgc_2046_web/router.ex`、`backend/config/deploy.yml`（oauth role：`/oauth`、`/.well-known/oauth-authorization-server` 两条前缀） |
| D-B5 | 单粗粒度 scope `cgc`：PRM 广告、授权服务器元数据、令牌 `scope`、打包 client 注册四处同源取值。授权能力 = 该账号全部工作台，与静态连接 token 等价 | `Cgc2046.Oauth2Server.scope/0` |
| D-B6 | DCR 开启以服务非打包宿主，但**回调一律限 loopback**（`127.0.0.1`/`::1`/`localhost`，端口任意；非 loopback 一律拒绝，人工批准为后续工作）；打包路径用**平台预注册的公开 client**（PKCE、无 secret），首公里不依赖注册端点。CIMD 不启用 | `Cgc2046.Accounts.OAuthClient`、`Cgc2046Web.Plugs.OAuthRegisterQuotaPlug` |
| D-B7 | **每次调用回查授权活跃性**：签名/`iss`/`aud`/`exp`/`nbf` 校验之外，再查该 (用户, client) 的刷新链是否仍活跃（未撤销、未轮换、未过期）；命中即触碰 `last_used_at`。撤销与闲置因此**即时生效**，不依赖 access token 自然过期 | `McpAuthPlug.authenticate_oauth/2`、`Cgc2046.Accounts.OAuthRefreshToken.verify_live/1` |
| D-B8 | 撤销语义 = **整条刷新链级联** + **撤回同意行**。第二段是必要的：库的授权端点命中同意行即直接发码、不再展示授权页，只撤凭证不撤同意等于被撤销的宿主可静默重新授权。RFC 7009 `/oauth/revoke`（宿主自撤销）走库的按 hash 级联路径，**保留同意行作审计行** | `Cgc2046.Accounts.OAuthAuthorizations.revoke/2`、`OAuthRefreshToken.revoke_authorization/2` |
| D-B9 | 签名密钥独立：专用 env `OAUTH2_SIGNING_SECRET`，缺失即启动失败，且启动自检拒绝与会话签名密钥同值 | `Cgc2046.Oauth2Server.validate_secrets!/0`（`Cgc2046.Application.start/2` 调用） |
| D-B10 | 授权**并入既有「已接入」判定与管理面**，不建第二套状态体系：`hasActiveCredential = 活跃 token 或 活跃授权`；撤销入口在授权页与用户级设置两处可达 | `web/lib/onboarding.ts`、MCP 页与用户级「连接与授权」页 |

**技术要点**

- **令牌与生命周期**（库默认 + 本平台覆盖）：access token 1 小时（HS256，`aud` 绑 resource）、授权码 10 分钟、刷新令牌 90 天**滚动**（每次轮换把新行 `expires_at` 前推，故「连续闲置超过 90 天」= 整条链无可用的未过期行，对齐既有连接 token 的 90 天滚动语义）、时钟偏差容忍 30 秒。
- **轮换与重用检测**：每次刷新轮换一行并继承 `chain_id`；已轮换令牌的二次使用判定为重用，整链撤销并返回 `invalid_grant`。
- **401 契约**：`WWW-Authenticate: Bearer realm=… error=invalid_token error_description=… resource_metadata=<PRM URL>` + JSON 体同义；撤销与闲置同形，不泄露凭证状态差异。`invalid_grant` 属令牌端点语义，由刷新失败返回（这正是宿主判定「需重新授权」的信号）。
- **节流分桶**：401 失败节流按 IP 且按凭证类型分桶（OAuth / 静态 token 各自一个 key，默认 20 次/15 分钟），注册配额独立（默认 10 次/小时/IP）。有效凭证的成功调用不计数——U2 实测宿主的自愈序列会频繁产生 401，不能把自愈路径堵死。
- **归因不变**：工具调用日志按凭证类型记录（`ToolCallLog.credential_type` ∈ `:oauth` / `:token`），`client_name` / `session_id` 仍取自请求上下文而非凭证路径。
- **配置入口**：生产在部署配置的 env 清单里给三个值（两个 URL 是公开值，签名密钥走 secret 名单，CI 侧有非空断言）；本地/测试各取各值，缺失即 raise（不设默认值——默认值等于静默用错域名）。

---

## 3. 不变量（改任一处都会断链）

### 3.1 `resource` 同值不变量

`resource` 是同一串 URL，出现在五处，外加一处派生：

| # | 位置 | 说明 |
|---|---|---|
| 1 | 宿主/客户端配置的 MCP URL | 学习空间包 `learn-space/opencode.json` → `mcp.cgc-2046.url` |
| 2 | 授权请求的 `resource=` 参数 | 库在 `/oauth/authorize` 校验：存在时**必须**与配置同值，否则 `invalid_target`（错误描述回显平台侧期望值）；缺省时回落配置值 |
| 3 | PRM 文档 `resource` | 宿主据 401 的 `resource_metadata` 取该文档，再据此发现授权服务器 |
| 4 | 访问令牌 `aud` | 签发时写入、每次调用校验比对 |
| 5 | 落库的 `resource_uri` | 授权码行与刷新令牌行；令牌端点逐项回验，刷新按 `resource_uri` 过滤 |

派生一处的值**不是** `resource` 本身：401 的 `resource_metadata` = `resource` 的 origin + `/.well-known/oauth-protected-resource`（库按路径替换生成）。

**结论**：改 api 域 MCP 路径或改协议暴露位置，必须同时改（1）包内配置与（2-5）平台 env；两侧不一致的首个症状是授权页报 `invalid_target`。

### 3.2 `issuer` 同值不变量

`issuer` 是另一串 URL，出现在三处：

1. 授权服务器元数据 `issuer`，并派生出四个协议端点 URL（库从 `issuer` 拼端点，挂载路径不可另改）；
2. 授权响应 `iss` 参数（RFC 9207，元数据同步广告该能力）；
3. 访问令牌 `iss` claim（校验时比对）。

派生约束：主域必须把 `/oauth` 与 `/.well-known/oauth-authorization-server` 两条前缀路由到后端（部署层路径路由，不 strip 前缀）；`issuer` 必须是**裸域**——登录 cookie 是 host-only，经 `www` 入口会丢登录态，授权页会退化成「登录后又要求登录」。

---

## 4. 后果（Consequences）

### 正面

- 非编程用户可以零 token 操作完成接入：浏览器登录 + 点一次确认；凭证不进入对话、日志与 URL。
- 撤销与闲置**即时生效**（活跃性回查），刷新失败返回标准 `invalid_grant` 让宿主自行清凭证并提示重新授权（U2 实测自愈：仅撤销 access 时约 1 秒内无交互恢复）。
- 凭证落库只存哈希；撤销保留审计行（web 撤销留链头回看、协议撤销留同意行），可回溯。
- 既有静态 token 解析路径与宿主 `mcp.url` 均未变（OpenClacky / OMP / DSH / 开发者手动 opencode 的接入地址不受影响）；其零回归按计划的既有测试与真机走查验收（R13/AE7）。
- 归因维度扩展而非替换：同一张工具调用日志上区分 OAuth 凭证与静态 token。

### 负面 / 风险

- **两条 RC 依赖进生产栈**（auth 栈 5.0-rc）。回退口径不是「换个版本」：OAuth 库强依赖 `ash_authentication ~> 5.0-rc`，回退整条 RC = 同时撤掉 OAuth 面（D-B1–D-B8 全部失效），因此故障处置优先 pin 到上一个可用 rc，而非回退到 4.14；回退步骤与门禁见运行手册。
- **新增匿名写端点**（DCR）。缓解 = 回调限 loopback + 按 IP 配额 + PKCE + redirect 精确匹配 + 同意页展示回调地址；非 loopback 注册拒绝会挡住「服务端回调」形态的客户端，这是首期有意的取舍（人工批准路径未实现）。
- **双路径并存有真实的短路风险**：宿主的配置是字段级深合并（U2 ④ 实测），全局同名条目里的静态 `Authorization` 头会**继承进**项目条目，宿主于是走静态路径、OAuth 永远不会触发。包内配置无法自行消除这一点，排查手段写进运行手册。
- **跨仓库不变量**（§3）：包内 URL 与平台 env 分处两个仓库，缺少自动化一致性校验，靠发布前检查与手册纪律维持。
- **共用电脑**：宿主凭证按 OS 用户共享（凭证文件在宿主全局数据目录），换人即继承会话 → 卸载口径必须包含 web 撤销与宿主登出（手册 §5）。
- **`signing_secret` 的双重用途**：既签 access token，也签同意页表单令牌；轮换会同时打断在途的同意流程（影响面与步骤见手册 §4）。

### Trade-off

| 权衡维度 | 选择 | 放弃 | 理由 |
|---|---|---|---|
| 授权服务器来源 | 官方 MCP 向库 0.3.1 | 自建最小 AS | 自建需自行承担 PKCE/轮换/撤销/元数据全套安全面；备选路径仅在 rc 出阻塞缺陷时启用 |
| 域划分 | issuer 在 web 域、resource 在 api 域 | 全部收进一个域 | 授权页要读主域登录 cookie（RFC 8414 又要求 issuer 与元数据同源），而 `mcp.url` 不能变（零回归） |
| 生效方式 | 每次调用回查活跃性 | 纯签名校验 + 短 TTL | 产品承诺撤销即时；代价是每次调用多一次 DB 读 |
| 撤销粒度 | 整链 + 撤回同意行 | 只撤当前 access / 只撤凭证 | 只撤 access 会被静默 refresh 绕过；不撤同意则被撤销的宿主可静默重新授权 |
| scope | 单粗粒度 `cgc` | 按角色/只读细分 | 与本期的能力等价承诺一致；细分无安全收益（工具层 RBAC 才是权限边界） |
| 注册政策 | DCR 开 + loopback 限 | 全关 / 全开 | 非打包宿主必须能自注册；服务端回调形态留给后续人工批准流程 |
| 认证纵深 | 复用既有插件链（双凭证） | 在 MCP server 层另起一套 authorization | 另起一套要重定义工具层的 actor 读取与 401 体/节流语义，收益仅是形态统一 |

---

## 5. 承接关系（对 ADR-0001 / ADR-0002 的取代与保留）

- **部分取代 ADR-0001 D13**（Onboarding = 一次性三步：装 OpenClacky → 粘贴 mcp.json + 生成连接 token → 扩展自动读 cgc 条目）。ADR-0002 的 D-A7 已经把「手动粘贴」改成「扩展自动配置」；本 ADR 再进一步：**非编程用户的默认路径不再经过任何 token**——安装官方宿主 → 获取模型通道 → 打开学习空间包 → 浏览器 OAuth 授权 → 会话内验证。D13 的「单一配置点、不做一条命令全自动」精神保留：学习空间是**项目级**开放配置文件（无秘密、卸装即删目录），不写用户全局配置。
- **扩展 ADR-0001 D6**（连接模型 = 单 MCP server + 每用户连接 token）：认证方式成为双凭证，但「绑用户、不绑工作区」「工具 = 形状、租户 = 过滤器、每次调用 = 审计记录」三条原则原样成立；新凭证以同样的用户契约进入工具层，并按凭证类型记录归因。
- **保留不变**：D3（零 AI 成本、用户出站连接）、D5（B 通道主干）、D9（平台自动记录工具调用）、D12（无状态 `workspace_id`）、D14（`cgc-2046` 命名与单一扩展不拆包）、ADR-0012（单一扩展 AGPL 与私有增量边界）。
- **降级而非删除**：静态 token 从「唯一路径」变为「开发者与既有宿主兼容路径」，代码与文档都不删（R13 零回归）；其管理面与 OAuth 授权在同一个界面呈现，判定取并集。

---

## 6. 拒绝的方案

- **自建最小授权服务器**：仅作为 rc 出阻塞缺陷时的备选路径（同 ADR-0001 的取舍方式：先验证官方库，失败再转）。
- **静态 token 过渡 / 插件配对**：产品决策阶段已否决——前者把 token 操作留给非编程用户，后者引入第二条自维护发布链。
- **CIMD（URL 形态 client_id）**：生态方向但当期无收益，且引入出站抓取面；DCR 已覆盖宿主需要。
- **在 MCP server 层启用库自带的服务端 authorization 纵深**：会要求工具层改读 auth claims，并重定义 401 响应体与失败节流语义，而现有插件链已经承担等价的鉴权与节流职责。
- **非 loopback 回调的自动注册**：桌面宿主场景不需要，且放宽即扩大匿名注册面；转人工批准需要先定义批准人、证据与审计，留作后续工作。
- **把 resource 也搬到 web 域（同一域收口）**：会改掉宿主配置的 `mcp.url`，直接破坏既有接入（R13）。

---

## 7. 落盘与实施影响

- 授权服务器与资源：`backend/lib/cgc_2046/oauth2_server.ex`、`backend/lib/cgc_2046/accounts/oauth_{client,authorization_code,refresh_token,consent}.ex`、`oauth_authorizations.ex`（读模型与撤销入口）、迁移 `backend/priv/repo/migrations/20260914172930_create_oauth2_server_tables.exs`。
- 资源服务器侧：`backend/lib/cgc_2046_web/plugs/mcp_auth_plug.ex`（双凭证 + 活跃性回查 + 401 发现头 + 分桶节流）、`oauth_register_quota_plug.ex`。
- 协议与页面路由：`backend/lib/cgc_2046_web/router.ex`（consent 管线与协议 scope）、`backend/config/deploy.yml`（oauth role 路径路由）。
- 宿主侧资产与引导：`learn-space/`（项目级配置与命令资产、打包脚本）、`web/components/agent-connect-sections.tsx` 与 `onboarding-wizard.tsx`（五步旅程单源）、`web/lib/onboarding.ts`（已接入判定）。
- 运维承接：`docs/运维/学习空间发布与OAuth授权运维.md`（包发布与版本纪律、RC 依赖升级/回退、授权故障排查、签名密钥轮换、共用电脑三步卸载口径）。
- 术语一致性：本 ADR 使用的词汇以 `CONTEXT.md` 为准；「宿主」「学习空间」「已接入」等以本 ADR 与计划文本为准。
