---
title: "Web 经微信小程序授权登录：实现与验收方案"
date: 2026-09-30
type: feat
status: accepted
topic: wechat-mini-web-login
baseline: d61cceb975b3957890016af6516bcbf18452ca4c
implementation_authorized: true
---

# Web 经微信小程序授权登录

## 1. 目标、决策与交付状态

短信服务商异常时，新用户仍能从 Web 发起注册，在微信小程序授权手机号后回到 Web 使用产品。后端继续按平台验证后的手机号查找或创建 User；Web、微信小程序、小红书使用同一手机号时复用同一 User，不先创建无手机号账号，不迁移或合并业务数据。

用户已选择本方向，并于本会话明确授权开始实施。授权包含代码与本地验证，不包含生产迁移、部署、小程序发布或生产凭证访问。真实微信手机号授权与手机返回链路仍是上线门，不能以本地测试替代。

成功标准：

- 新用户可在完全不调用本项目短信发送/验码接口的情况下完成 Web 注册、默认工作区入座与登录。
- 已有同手机号小红书/微信/手机号账号被复用；用户 ID、已有报名、订单、成员角色不变。
- 扫码和小程序自身登录不会自动授权 Web；必须明确点击“确认登录网页版”。
- 只有发起请求的浏览器能取得 Web Cookie；小程序登录态不被 Web 签发动作吊销。
- 电脑扫码、iOS/Android 外部浏览器、微信内网页均完成真实链路验收；允许手机用户手动返回原网页。

范围：后端登录交接、Web 登录入口、微信小程序确认页、必要的契约/深链/测试/文案变更。预计涉及超过 8 个源文件，且有一张新短期票据表；不增加服务、第三方依赖或凭证种类。

不包含：账号合并、无手机号注册、UnionID 归并改造、小红书/抖音新增登录入口、权限调整、短信服务商修复、手机号换绑规则变更、支付或学习数据迁移。不同手机号与历史重复账号不承诺互通。

## 2. 当前实现证据与可复用边界

以下路径相对仓库根目录；行号以基线为准。

| 证据 | 当前行为 | 本次用途 |
| --- | --- | --- |
| `backend/lib/cgc_2046/accounts/strategies/miniprogram/sign_in_preparation.ex:66` | 获取平台手机号后调用 `SignInFlow.find_or_create_user`，再挂平台身份 | 复用现有小程序登录，不新建第二套手机号认证 |
| `backend/lib/cgc_2046/accounts/sign_in_flow.ex:52` | 按手机号查找/创建，唯一索引处理创建竞态 | 同号复用、并发只建一个 User |
| 同文件 `:93`、`:131` | 按平台吊销/签发 JWT | 领取时只处理 Web token，保留小程序 token |
| `backend/lib/cgc_2046/accounts/wechat_web_sign_in.ex:48` | 网站 OAuth 新身份转 `needs_binding`，需要短信 | 新入口不经过此分支 |
| `backend/lib/cgc_2046/accounts/wechat_login_ticket.ex` | 网站 OAuth 票据，含 openid/access_token 与专用状态机 | 不把小程序确认语义塞入这张表 |
| `backend/lib/cgc_2046_web/plugs/auth_cookie_plug.ex` | GraphQL 完成时写 host-only、HttpOnly Cookie | 扩展同一 Cookie 写入出口 |
| `backend/lib/cgc_2046/integrations/wechat/client.ex:319` | 生成小程序码，现有目标是邀请页 | 提取可指定发布页面的公共生成能力，原邀请调用行为不变 |
| `backend/lib/cgc_2046/integrations/wechat/url_link.ex` | 已有 URL Link 生成 | 手机入口复用 |
| `miniprogram/src/pages/login/index.tsx:34` | 登录后支持安全的站内 `returnUrl` | 登录完成回到确认页 |
| `miniprogram/src/domain/share-route.ts:245` 与 `entry.ts` | 冷/热启动统一路由，`scene` 默认是邀请凭据 | 为登录码增加独立分支，不污染 `pendingScene` |
| `miniprogram/src/domain/platform-pages.ts` | 微信/小红书/抖音页面注册单源 | 确认页只注册到微信端 |
| `docs/adr/0008-browser-session-single-origin.md` | 浏览器会话只属于 Web 主域，禁止扩大 Cookie Domain | 开始、查询、领取均经 Web 同源 GraphQL；小程序仍访问现有 API |

采用最小方案：已有微信手机号登录 + 短期登录请求 + 有界轮询。暂不使用 WebSocket、通用账号关联框架或完整 OAuth Device Authorization Server。

借鉴 [RFC 8628](https://www.rfc-editor.org/rfc/rfc8628.html) 的“另一设备确认、发起设备轮询、领取凭据与展示标识分开、到期停止”机制；本接口不是 RFC 8628 实现，也不宣称与其协议兼容。微信网站 OAuth 不提供本需求的手机号授权闭环，因此本次入口直接使用小程序。

## 3. 产品流程

### 3.1 电脑浏览器

1. 进入 Web 登录页，点击“微信登录”，创建请求并显示小程序码、剩余有效时间及取消/刷新入口。
2. 微信扫码进入 `pages/web-login/index`；先检查请求是否有效，再引导账号登录，避免为已失效请求索取手机号。
3. 有有效微信登录态且 User.phone 非空：显示当前账号的显示名/掩码手机号。否则进入现有手机号登录页，完成后返回确认页。
4. 显示“登录程序媛汇网页版”“仅确认你本人刚刚发起的登录”。提供“确认登录”“取消”“切换账号”。切换账号只调用现有退出/登录逻辑，不改变手机号换绑规则。
5. 用户确认后，后端将本次请求锁定到该 User。手机提示“已确认，请返回刚才的网页”。
6. Web 查询到 `APPROVED` 后主动领取 Cookie，刷新当前用户缓存，按现有安全回跳规则回到原页面。

未登录用户的手机号授权与 Web 确认保留两个明确步骤，复用现有协议同意流程。不能把授权手机号解释为已经同意登录另一设备。

### 3.2 手机浏览器与微信内网页

- 默认显示“打开微信小程序登录”；保留“使用二维码”切换入口，设备判断只决定显示默认值，不作为认证依据。
- 在展示按钮前准备 URL Link；点击时进行顶层导航，避免异步生成后新开窗口被浏览器拦截。
- 在原标签页的 `sessionStorage` 只保留非秘密 requestId 与入口模式；回跳路径沿用当前页面的 `next` 参数和既有安全校验，不重复存储。不保存 JWT、手机号、微信 code、浏览器证明。
- 小程序确认后提示手动返回原浏览器。Web 的 `pageshow`、`visibilitychange` 恢复时立即查状态；不得在恢复时无条件新建请求。
- 不以小程序 web-view 重新打开网站来替代原浏览器；不承诺微信能自动切回 Safari、Chrome 或特定微信网页实例。
- 原标签页被关闭、浏览器证明丢失或请求过期时重新开始，不跨浏览器转移领取权。

### 3.3 取消、新用户与失败含义

- Web 的取消/刷新会在后端取消旧请求。小程序“取消”只退出本次确认，不赋予任何持有公开二维码的人远程取消浏览器请求的能力；Web 可自行取消或等待到期。
- 已完成小程序注册、尚未确认 Web 的用户仍保留正常小程序账号；取消 Web 不删除 User，不回滚已经完成的小程序注册。
- 业务不可用、微信额度不足时明确显示原因和重试入口，保留其他现有登录方式；不自动退回强制短信绑定。

## 4. 责任边界和数据流

```text
Web 主域浏览器 -- 开始 / 查询 / 领取（独有 Cookie） --> Accounts 登录交接
      |                                                     |
      | 小程序码 / URL Link（公开定位符）                   | 短期请求表
      v                                                     |
微信小程序 -- 现有手机号登录 --> Accounts 现有认证           |
      |                                                     |
      +-- 用户确认（有效微信 Bearer） -----------------------+

微信服务端：提供小程序码、URL Link、登录凭证换取和手机号验证。
业务资源：继续只读/写已确定的 User，不接触报名、订单、角色迁移。
```

- `Accounts.WechatMiniWebLogin`：用例编排、授权条件、限流、开始/确认/领取事务。
- `Accounts.WechatMiniWebLoginRequest`：Ash 内部资源、状态与期限、CAS/行锁，不自动暴露 GraphQL CRUD。
- `Integrations.Wechat.WebLoginLaunch`：组合小程序码与 URL Link 的展示结果；调用现有微信集成，不能决定登录账号。
- GraphQL/Plug：协议输入、可信 Cookie/已验证 Bearer context、错误码、Cookie 交付；不在 resolver 内实现建号规则。
- Web/小程序 domain：展示状态、轮询节奏、深链判定；页面负责渲染与用户操作。

手写模块保持在 500 行以内；现有 `Client` 大文件只做接缝调整，新增登录逻辑放入独立模块。无 Redis、无后台常驻轮询进程、无新增 npm/Hex 依赖。

## 5. 后端契约

### 5.1 新短期请求表

新建 `wechat_mini_web_login_requests`，不修改 `users` 或 `user_identities` 的表结构。

| 字段 | 约束/用途 |
| --- | --- |
| `id` | UUID 主键，仅内部引用 |
| `public_code` | 16 随机字节经无 padding base64url 编码，22 字符，唯一；公开定位符 |
| `browser_proof_hash` | 独立 32 随机字节证明的 SHA-256 摘要；原值只写浏览器 HttpOnly Cookie |
| `browser_rate_key` | 随已验证的旧请求继承；刷新旋转 proof 时不重置浏览器限流计数 |
| `status` | `pending / approved / consumed /cancelled` |
| `user_id` | pending 为空；approved/consumed 必填，由认证 actor 写入，不接收客户端 userId |
| `expires_at` | 创建起 10 分钟，确认不延长；过期由读写检查派生为 `EXPIRED` |
| `approved_at / consumed_at / cancelled_at` | 对应迁移时间 |
| `consumed_jti` | consumed 时记录本次 Web token 的 JTI，供原浏览器恢复核对；不存 token、不对外返回 JTI |
| `inserted_at / updated_at` | UTC 时间 |

新表建立 `public_code` 唯一索引和 `expires_at` 索引；User FK 用限制删除的语义，不在用户删除时转移授权。Ash references、snapshot、迁移及 FK/index 守卫同步。清理接入现有 `LoginArtifactPrunerWorker`：保留到期后 1 天，沿用小时清理。过期检查不能依赖清理任务及时运行。

不存手机号、微信 access_token、session_key、原始 JWT 或完整 URL Link。公开码与 proof 必须独立随机生成；不能把现有 OAuth state 同时用作二维码内容和领取证明。

### 5.2 状态与并发

```text
pending -- 确认 --> approved -- 原浏览器领取 --> consumed
pending / approved -- 原浏览器取消或刷新 --> cancelled
pending / approved -- 到期 --> EXPIRED（派生终态）
```

- 迁移须锁定该请求/原子 CAS，并在锁内复查期限、状态和身份。确认与取消/过期/领取竞态只允许一个合法结果。
- 同一 User 重复确认 approved 请求返回同一状态；不同 User 不能改写已确认账号。确认不签发 Web token。
- 领取把 User 有效性重查、Web 旧 token 吊销、新 token 持久化、consumed_jti 和 consumed 状态放在同一数据库事务；任何一步失败全部回滚。实际签发/存储函数必须通过失败注入证明共用事务。
- 原请求已 consumed 时不再次签发 token。若响应体丢失但 Cookie 已到达，status 在校验原浏览器 proof 后，将当前有效 Web token 的 JTI/subject 与 consumed_jti/user_id 核对，匹配才返回 `sessionEstablished=true`，Web 再读 `me`；若 Cookie 也丢失，返回 false 并提示重新扫码，不永久保存 JWT 以支持重放。不会因此重复创建 User。
- 同一浏览器一次保留一个可领取请求。新开始/刷新旋转 proof 并取消能由旧 proof 证明的请求；多标签页旧请求显示“登录请求已更新”。并发 start 最终以浏览器收到并持有的 proof 为准，其余票据无法领取并自然清理。
- Web 已登录且当前账号与待领取账号不同，拒绝静默换号，提示先退出后重试；相同账号也必须校验本次请求，不把 `me` 任意成功当成本次领取成功。

### 5.3 GraphQL 操作（拟新增）

浏览器操作统一走主域同源 `/api/graphql`；状态查询使用 POST 与 no-store，不新增 api 子域浏览器会话。

| 操作 | 输入 | 认证与输出 |
| --- | --- | --- |
| `wechatMiniWebLoginStart` mutation | `mode: QR / LINK` | 校验浏览器请求来源，返回 `requestId`（public_code）、`status`、`expiresAt`、`pollIntervalSeconds=3`、相应 `qrDataUrl` 或 `launchUrl`；before_send 写独有 proof Cookie |
| `wechatMiniWebLoginStatus` query | `requestId` | 校验浏览器 proof；返回状态、期限、`sessionEstablished`，不返回账号、手机号、JTI 或 JWT |
| `wechatMiniWebLoginPreview` query | `requestId` | 小程序可在登录前调用，只返回请求可用性/期限与固定产品名称，不泄露账号信息 |
| `wechatMiniWebLoginConfirm` mutation | `requestId` | 需要有效微信小程序 Bearer、phone 非空的 actor、归属该 actor 的微信身份；返回状态，不下发 Web Cookie |
| `wechatMiniWebLoginConsume` mutation | `requestId` | 浏览器 proof + approved 状态；返回已登录用户 ID，JWT 仅通过既有 `cgc_auth_token` Cookie 出口交付 |
| `wechatMiniWebLoginCancel` mutation | `requestId` | 浏览器 proof；幂等取消未消费请求，不退出已经建立的用户会话 |

`requestId` 只接受 22 字符合法 base64url；抖音/小红书/Web token、伪造 platform claim、匿名请求不能确认。平台信息必须来自已完成签名/有效期/撤销校验的 token context，不能仅 decode JWT 或相信请求参数。User 与平台身份不符时拒绝，不 upsert 重指向。

浏览器 proof Cookie 拟命名 `cgc_mp_web_proof`，host-only、HttpOnly、SameSite=Lax，secure 沿用现有环境设置，最长 600 秒。start/consume/cancel 校验可信 Web origin、JSON POST 与既有代理规则；不把任意 Host/Origin 反射成允许来源。校验浏览器 proof 时使用定长摘要安全比较。

只复用现有主域与小程序 AppID/Secret 配置，不新增密钥、不展示实际值。发布前检查非个人认证主体、手机号额度、请求合法域名及正式版页面可用性。生产事实由发布负责人确认，本文没有宣称已检查。

### 5.4 限流、故障与错误码

固定初值，不新加配置旋钮：start 每浏览器 1 次/3 秒、20 次/小时，每可信客户端 IP 60 次/小时；preview/status 每请求 30 次/分钟，preview 另有每 IP 120 次/分钟；confirm 每 actor 20 次/分钟；consume/cancel 每请求 10 次/分钟。继承项目限流工具，测试确认代理后 IP 没有退化为所有用户共用一个桶。

Web 常态每 3 秒查询一次；隐藏、卸载或终态即停止。瞬时网络错误按 3/6/12/15 秒退避，到期或取消即终止；现有限流错误契约不返回 retryAfter，轮询遇到限流固定等待 60 秒（匹配状态查询的限流窗口），仍受请求期限约束。不无界重试，不弹出假成功。过快查询拒绝，不能仅依靠前端计时器。

微信出码/短链请求单次超时上限 8 秒；自动重复调用为 0，用户点击重试触发新调用并受限流。QR 模式只生成码，LINK 模式只生成短链，避免无用外部调用。每请求生成一次，页面恢复只查询状态；新票据失败时不展示半成品码。URL Link 创建有效期使用现有模块的 1 天参数，登录权仍由 10 分钟票据决定。

错误码在 domain 层显式定义并进入项目错误契约：`mini_web_login_invalid`（含未知请求/错误 proof，不泄露差异）、`mini_web_login_expired`、`mini_web_login_cancelled`、`mini_web_login_not_approved`、`mini_web_login_consumed`、`mini_web_login_account_conflict`、`mini_web_login_phone_required`、`mini_web_login_unavailable`、`mini_web_login_failed`。限流复用现有 rate-limited 契约。不得向客户端输出微信原始错误响应、token 或手机号。

## 6. 小程序码、URL Link 与路由

- 唯一落点 `pages/web-login/index`，只加入 `WEAPP_PAGES`。正式码 `page` 不带 query，`check_path=true`、`env_version=release`。
- QR 使用 `scene=wl_<public_code>`（25 字符，满足 32 字符限制）；URL Link 使用同一落点，链接后 `cq=wl_<public_code>`，参数只含公开定位符。
- 仅当平台为微信、入口 path 为确认页、参数格式正确时进入登录分支。若 scene/cq 同时存在但不一致，或混入邀请/分享目标参数，拒绝为无效请求。
- 此分支在邀请路由之前解析，不写 `pendingScene`，不消费或清除已有邀请凭据；其他页面携带 `wl_` 不应被解释成有效登录入口。
- 冷启动已在目标页时不二次跳转；热启动即使当前也在确认页，只要 requestId 不同就重置页面并加载新请求，不能沿用前一次确认状态。
- 登录 returnUrl 仅允许已注册的站内页面与合法 requestId；拒绝外部 URL。页面恢复重新查期限，再允许确认。
- 现有 `UrlLink` 和生成码接缝可复用；不直接改全平台的邀请码默认 page，也不改变闪念间 `cq` 解析。

## 7. 实施文件与工作包

实施前在独立 feature worktree 重新核对基线和最新规则；下列为目标，不要求为了命名创建空文件。所有非平凡行为先写失败测试，再实现，最后做守卫变异验证。

| 工作包 | 目标文件/目录 | 完成标准 |
| --- | --- | --- |
| I1 后端领域 | `backend/lib/cgc_2046/accounts/wechat_mini_web_login.ex`、`wechat_mini_web_login_request.ex`、`accounts.ex`；新迁移和 resource snapshot | 状态、proof、确认、事务领取通过 HTTP 入口测试 |
| I2 协议与清理 | `backend/lib/cgc_2046_web/graphql_schema/auth/mini_web_login.ex`、auth/types 与 schema import；新增 proof context Plug、`auth_cookie_plug.ex`、`router.ex`；`login_artifact_pruner_worker.ex` | 跨请求 Cookie/认证链有效，公开面不泄露凭证，票据可清理 |
| I3 微信启动 | `backend/lib/cgc_2046/integrations/wechat/web_login_launch.ex`、`client.ex` 的出码接缝、复用 `url_link.ex` | QR/LINK 各自调用正确接口，正式页面/参数/超时有契约测试 |
| I4 微信客户端 | `miniprogram/src/pages/web-login/index.tsx`、样式/config；`domain/web-login.ts`、`share-route.ts`、`platform-pages.ts`；`api/web-login.ts`、operations/mockTransport/generated | 冷/热启动、登录返回、显式确认；xhs/tt 包不含入口与导流文案 |
| I5 Web | 登录 `wechat-qr-panel.tsx` 改为小程序入口；独立 `use-mini-web-login.ts` 管理生命周期；`web/lib/graphql/mini-web-login.ts`、登录导航与全部 locale 文案 | 等待/过期/取消/恢复/领取状态闭环，Cookie 不由 JS 保存 |
| I6 契约和说明 | `backend/priv/graphql/schema.graphql`、`priv/error_codes_contract.json`、小程序 error-copy 与生成产物、`CHANGELOG.md` | 生成文件和源契约一致，记录行为和发布依赖；本方案关键认证决策在实施 PR 同步记录为待接受 ADR |

既有网站 OAuth API 是已经上线的契约，本期不删除、不改输入输出；它不会作为新路径失败后的自动 fallback。切换的是 Web 当前入口。旧回调/绑定页继续服务已经打开的旧流程，旧票据按原 10 分钟规则到期；公开 API 的后续撤除需另案确认，不能把“等待 10 分钟”误当所有缓存客户端已退出。保留这些 live API 是现有依赖要求，不引入新的兼容层或双写。

## 8. 验收矩阵

自动化认证测试优先通过真实 HTTP `/api/graphql` + Cookie/Bearer + 隔离 PostgreSQL；只 mock 微信外部服务。UI/mock 测试不代替真实微信授权。测试使用合成用户与手机号，不读取生产数据。

| ID | 场景 | 必须断言 |
| --- | --- | --- |
| A01 | 全新用户，短信服务完全不可用 | 小程序手机号授权→确认→Web `me` 成功；User 仅新增 1 条、默认入座成功；短信发送/消费调用次数为 0 |
| A02 | 已有小红书手机号账号，附报名和订单 | 微信授权同号后 Web、小程序、小红书使用同一 user_id；报名/订单/角色数量及状态不变 |
| A03 | 已有微信有效登录态 | 只需确认；不请求手机号，不增加 User；小程序 token 在 Web 登录后仍有效 |
| A04 | 匿名/缺手机号/错误平台/失效 token | 不得确认或领取；伪造 userId/platform 不改变结果 |
| A05 | 仅扫码、仅小程序登录、拒绝手机号 | Web 仍未登录；完成小程序注册后取消不删除新 User |
| A06 | 只持二维码 public_code 或另一个浏览器 proof | 无法查私有状态、取消或领取；URL/响应/日志无手机号、proof、JWT |
| A07 | 跨站 start/consume/cancel、外域 returnUrl | 拒绝；Cookie 保持主域 host-only，无 Domain 扩大、无开放跳转 |
| A08 | 同用户重复确认、两用户并发确认 | 同用户幂等；一个最终绑定账号，另一个明确冲突，不最后写入者获胜 |
| A09 | 确认与取消/刷新/过期同时发生 | 仅一个合法状态；旧请求不能签发；过期清理未运行时仍拒绝 |
| A10 | 并发领取、JWT/存储/吊销失败注入 | 至多一个成功领取；失败无半消费/半吊销；小程序 token 不受影响 |
| A11 | 消费响应丢失 | Cookie 到达则通过 status 核对本次 consumed_jti 与有效会话恢复；其他旧 Cookie 不得被误认；Cookie 未到则重新扫码，不重复建号或重放旧票据 |
| A12 | Web 已登录其他账号 | 不静默切换，提示退出重试；同账号恢复不会误判其他请求成功 |
| A13 | 冷启动/热启动、同页不同 requestId | 进入正确确认页；无重复导航；旧账号/旧确认结果不串入新请求 |
| A14 | scene/cq 冲突、畸形参数、邀请混入 | 拒绝混合登录参数；不写 pendingScene；原邀请与闪念间链路回归通过 |
| A15 | Web 隐藏、刷新、断网、多标签页 | 原请求恢复；无后台忙轮询/并发查询；旧标签明确失效；限流/退避生效 |
| A16 | 微信出码失败、额度不足、短链失败 | 具体可重试错误，不生成无手机号账号、不假成功、不自动转短信绑定 |
| A17 | 小程序未发布该页/旧客户端 | 正式出码校验拒绝或提示更新，不能开启一个必失败的 Web 入口 |
| A18 | 清理、新迁移回滚和索引/FK 守卫 | 只清理到期超过 1 天请求；down 移除新表且无残留；不改变业务表 |
| A19 | 微信/小红书/抖音回归 | 原手机号/静默登录不变；xhs/tt 无确认页与新增导流文案；所有端构建通过 |
| A20 | 主域/模拟 api 子域隔离 | 真实主域代理链下设置并读取 Cookie；仅 localhost 不算验证通过 |

### 8.1 真机必验

| 设备/入口 | 操作 | PASS 证据 |
| --- | --- | --- |
| 桌面 Chrome + 手机微信 | 新用户扫码授权、确认、原电脑跳回报名页 | 两端录像/截图 + 脱敏请求状态 + 后端 user_id 相等断言 |
| 桌面 Safari + 手机微信 | 已有用户确认登录 | 不弹手机号授权；Web/小程序可继续使用 |
| iOS Safari | 点击 URL Link、确认、手动切回原标签页 | 原请求恢复并登录，无额外建号 |
| Android Chrome | 官方中转页→小程序→返回原网页 | 浏览器未丢失 proof，原网页完成登录 |
| iOS 微信内网页 | 点击进入小程序、返回原微信网页 | 同一网页实例领取成功 |
| Android 微信内网页 | 同上，并覆盖取消/重试 | 取消不登录、重试成功 |
| 小红书老用户 | 同手机号的微信授权后访问已有报名 | user_id、数据归属一致；不发生合并 |

每份报告写设备/OS/微信版本、Web/后端 commit、小程序版本、场景 ID、结果及脱敏证据。任何一个必须支持的入口未通过，标记未完成并阻止 Web 切换，不以模拟器绿测替代。真机需要用户操作系统授权时，由用户执行授权，agent 收集结果。

### 8.2 测试命令与顺序

以下在实施 worktree 对应目录执行。关键验收文件名按实际实现列出；具体运行证据单独记录，不由命令清单推定通过。

Backend（先对所用 Mix task 执行 `mix help <task>`）：

```sh
mix test test/cgc_2046_web/graphql_wechat_mini_web_login_test.exs
mix test test/cgc_2046/integrations/wechat/web_login_launch_test.exs
mix cgc2046.gen_error_codes_contract
mix absinthe.schema.sdl --schema Cgc2046Web.GraphqlSchema priv/graphql/schema.graphql
mix ash_postgres.generate_migrations --snapshots-only
mix ash_postgres.generate_migrations --check
mix precommit
```

Web：

```sh
pnpm vitest run 'app/[locale]/(auth)/login/wechat-qr-panel.test.tsx' 'app/[locale]/(auth)/login/use-mini-web-login.test.tsx'
pnpm typecheck
pnpm lint
pnpm test
pnpm build
```

小程序：

```sh
./node_modules/.bin/graphql-codegen-cjs --config codegen.yml
node --experimental-strip-types --test tests/web-login.test.ts
pnpm check:ci
node e2e/web-login.e2e.mjs
```

新增 E2E 脚本登记到小程序 E2E 文档与锚点规则；页面状态函数在 domain 用 node:test 验证，真实操作走微信开发者工具，Web 走 ego-browser。真实微信接口只在受控真机验收运行，服务端集成测试不得误发短信或消耗真实手机号额度。

变异验证至少覆盖：移除 proof 检查、移除确认前置条件、移除期限检查、移除状态 CAS、把 Web 吊销范围改为全平台、让登录 scene 写入 pendingScene。每个守卫均保留“改坏变红→还原变绿”输出；并发用屏障/消息协调，不用 sleep 制造偶然通过。

## 9. 发布、退回与观测

### 9.1 两个可独立交付的包

R1：后端新增能力 + 小程序确认页及契约。现有 Web 入口和各端原登录仍可用；新能力可由授权测试浏览器调用，正常用户没有新入口。先由人部署后端，再由人上传/审核/发布小程序。小程序先行误遇旧后端时显示“功能暂未开放”，不能绕过认证。

R2：小程序正式页存在、R1 后端/小程序验收通过后，在受控验收环境部署 R2 Web 候选版本，以与生产相同的主域代理/Cookie 边界完成全部真机矩阵，再由人切换生产 Web 登录面板。测试环境只用获授权的测试账号与相匹配的后端/小程序配置，不把生产数据复制到测试库。发布过程不新增运行时 feature flag；每个包的代码都必须完整可运行，R2 不能承担补完 R1 的责任。迁移触及人工合并范围，合并/发布按项目授权由人执行。

本次按用户直接实施指令开展手动会话的本地工作，不擅自创建 issue 或修改标签。进入 LoopX 自动交付或提交 PR 前，实施负责人应将 R1/R2 及验收清单关联到 `ready-for-agent` issue，并遵守质量门；本次指令不授予发布权限。

### 9.2 退回

- R2 出现问题：由人将 Web 入口退回上一版本，停止新请求；新请求最长 10 分钟失效，已登录用户 Cookie 继续按现有规则有效。
- 恢复旧入口会恢复其短信依赖，不能宣称故障仍被解决。需要继续修复 R2 后再切换；不偷偷放宽手机号校验。
- R1 应用可退回且保留未使用的新表。生产不自动执行 down 或清空票据；下线后清理表需按迁移/发布授权另行执行。隔离测试必须证明 down 不影响任何业务表。
- 不迁移/回滚报名、订单、角色、学习数据。小程序已正常注册的 User 不因 Web 发布退回而删除。

### 9.3 观测与上线门

记录 `started / approved / consumed / cancelled / expired / launch_failed / consume_failed / rate_limited` 计数及确认到领取耗时，维度只含 QR/LINK 与受控错误类别。日志使用内部请求主键关联排障，不打印 public_code、proof、启动 URL、code、session_key、JWT 或手机号；公开报告不放内部标识。

上线前人工核对：正式小程序确认页、主体/手机号额度、请求域名、Web 同源代理、iOS/Android 六类浏览器矩阵、A01/A02 零短信与同号复用证据。发布后首轮真实新/老用户冒烟失败、出现错误账号登录或跨浏览器领取成功立即停止新入口并退回；一般错误看计数定位，不以重试掩盖。

## 10. 官方依据、假设与评审结论

2026-09-30 已读取以下官方页面。可达仅说明文档可读，不代表本项目生产账号权限、接口额度、开发者工具或真机链路已验证。

- [手机号快速验证](https://developers.weixin.qq.com/miniprogram/dev/framework/open-ability/getPhoneNumber.html)：需用户同意，服务端消费授权 code；额度不足会失败。平台验证不等同每次实时短信验证，用户新增号码可能需要微信侧验证。本方案承诺不依赖本项目短信通道，不承诺微信永不出现短信。
- [URL Link](https://developers.weixin.qq.com/miniprogram/dev/framework/open-ability/url-link.html)：已发布小程序、适用主体、官方中转页与 cq 参数。
- [不限制数量的小程序码](https://developers.weixin.qq.com/miniprogram/dev/server/API/qrcode-link/qr-code/api_getunlimitedqrcode.html)：页面、scene 长度、发布校验与环境。
- [RFC 8628](https://www.rfc-editor.org/rfc/rfc8628.html)：只借鉴异设备授权的控制权分离与有界轮询，不引入标准协议实现。

最脆弱的假设是手机浏览器经微信跳转后仍能保留原 Cookie 并恢复原标签页。设计已允许手动返回、恢复查询和明确重新开始，但最终支持承诺必须由真机矩阵证明。另一个上线前提是小程序手机号额度可用，额度不足时本方案无法为新用户取得手机号，需明确显示不可用并由运营恢复额度。

方案已获用户实施授权；代码与本地验证按 I1–I6 完成后，仍须按 R1/R2 发布依赖和真机上线门执行。不重新引入账号合并。架构选择见 ADR-0019，验收证据见[本地验收报告](../validation/2026-09-30-wechat-mini-web-login.md)。
