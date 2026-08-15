---
title: "Web 找回密码流程 - Plan"
type: feat
date: 2026-08-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
deepened: 2026-08-15
---

# Web 找回密码流程 - Plan

## Goal Capsule

- **目标**:为 web 账号(纯密码制)提供自助找回密码:忘记密码 → 邮件重置链接 → 一次性 token 重置密码。上线后忘记密码不再依赖数据库手术。
- **权威层级**:R(产品行为)> KTD(实现机制)> Unit 局部决策。冲突时按此序裁决。
- **执行画像**:后端 Elixir/Ash(backend/)+ 前端 Next.js(web/),零新增依赖、零数据库迁移。
- **停止条件**:R1–R8 全部满足、验证合同门禁全绿、E2E 全流程走通。
- **收尾归属**:本计划自身含完整交付尾(测试 + E2E 验证);不依赖后续计划。

---

## Product Contract

### Summary

web 端新增找回密码能力:登录页提供入口,用户提交注册邮箱后收到含一次性重置链接的邮件(24 小时有效),经链接设置新密码。重置成功后该用户全部已签发会话吊销。生产邮件经 SendCloud API 发送,邮件通道同时服务正式运营。不做独立邮箱验证流——找回密码流程本身即完成邮箱所有权首次验证。

### Problem Frame

web 账号是纯密码制:忘记密码 = 账号连同报名记录永久丢失。没有管理员重置密码通道,兜底只能靠数据库手术。面向公众的产品不能没有自助找回。邮件服务(SendCloud)本就是正式运营的必要依赖,本次一并接入。

### Key Decisions

- KD1. 不做独立邮箱验证流,找回密码流程本身完成邮箱所有权验证(一个流程两个作用)。Governs R3。(session-settled: user-directed — chosen over 单独验证邮件流: 流程少一条,验证语义由 reset token 达成)
  - Call-out(已接受代价):sign_up 无邮箱验证,他人可先占注册他人邮箱;真实邮箱主人完成重置即接管该占位账号(含其名下报名记录)——接管语义视为产品预期(邮箱所有权即账号所有权);占位者亦可对真实邮箱发起重置、触发莫名邮件,该骚扰面靠 R6 限流缓解,根治需 sign_up 验证流(不在本计划)。
- KD2. 邮件服务商使用 SendCloud。Governs R7。(session-settled: user-directed — chosen over 其他集成商: 已选定供应商,国内送达率适配)
  - Call-out(已接受代价):链接 24h 有效且允许多枚并存,邮箱被转发/镜像场景下存在被点击窗口;由每枚一次性 + 重置成功后全部吊销收敛爆炸半径。

### Requirements

找回流程:

- R1. 登录页提供「忘记密码?」入口,进入仅含 email 输入的表单页 `/forgot-password`。
- R2. 提交重置请求后,无论邮箱是否已注册,响应内容无可区分差异(`sent: true` / 统一文案);时间面消除主差异源(邮件外呼不进入请求路径),残余时间差不承诺恒时化(见 Scope Boundaries 已接受残余风险)。
- R3. 已注册邮箱收到重置邮件,内含一次性重置链接,24 小时内有效;多枚未用链接可并存(重复请求各发一封),任一枚完成重置后其余全部失效。
- R4. 经链接进入 `/reset-password?token=...`,提交新密码后密码更新;token 过期、已使用或伪造时统一报「链接无效或已过期」,且页面提供重新申请入口。
- R5. 密码重置成功后,该用户全部已签发会话(web 与小程序)在同一事务内吊销,须重新登录;吊销失败时整个重置失败回滚(不留「密码已改但旧会话仍活」的中间态),失败必须告警,不得静默。

安全与滥用防护:

- R6. 重置请求三层限流,key 均使用归一化(小写、去空白)email/IP:按 IP+email 15 分钟 5 次(与登录同档);按 email 全局每小时 5 次(跨 IP 合计,防换 IP 轰炸单一邮箱);按 IP 跨邮箱每小时 20 次(防单 IP 群发消耗配额)。大小写变体共享配额。
- R8. 新密码规则与注册一致(最少 8 位);违规时错误指向密码字段(非「链接无效」),且 token 不被消耗。

邮件通道:

- R7. 生产环境邮件经 SendCloud API 发送;发送失败不阻塞接口响应,且经 telemetry + 日志可观测;告警载荷不得包含明文 token、重置链接或完整 email。

### Acceptance Examples

- AE1. **邮箱未注册**:Given 该邮箱无用户,When 提交 `/forgot-password`,Then 响应 `sent: true`,无邮件发出,无错误差异。Covers R2。
- AE2. **SendCloud 故障**:Given 已注册用户,When 请求重置且 SendCloud API 报错,Then 响应仍 `sent: true`,telemetry 记录 error 且载荷不含 token/完整 email。Covers R2, R7。
- AE3. **token 二次使用**:Given 某重置链接已成功使用,When 再次以同 token 提交,Then 返回「链接无效或已过期」。Covers R4。
- AE4. **重置后旧会话失效**:Given 用户在 web 与小程序各有一个活跃会话,When 密码重置成功,Then 两端 token 均被吊销,旧密码登录失败,新密码登录成功。Covers R4, R5。
- AE5. **邮件轰炸防护**:Given 攻击者对同一邮箱换不同 IP 提交重置请求,When 该邮箱当小时累计达 5 次,Then 第 6 次被拒;大小写变体计入同一配额。Covers R6。
- AE6. **重置成功废止全部未用链接**:Given 用户有两枚未用重置链接,When 以其一完成重置,Then 另一枚即刻失效(再提交返回「链接无效或已过期」)。Covers R3, R5。

### Scope Boundaries

不做(deferred / non-goal):

- 独立邮箱验证流(KD1)。
- `email_verified_at` 落库(KTD6)。
- 管理员后台重置他人密码通道。
- 邮件发送异步化(Oban 队列)——流量极低,失败靠 R7 可观测性暴露,成瓶颈再迁。KTD4 的 fire-and-forget 仅解耦单次外呼,不是队列。
- 邮件模板美化(终稿文案可后续迭代,不阻塞;信息要件见 U2)。
- timing 侧信道的完整恒时化——KTD4 消除主差异源(外呼出请求路径),不构造恒时伪工作;残余差异(已注册路径的 token INSERT + JWT 签名写/CPU 开销)不做处理,记为已接受残余风险。
- 「任一时刻仅一枚有效 reset token」不变量——实现代价为请求时吊销全部会话(reset token 与会话 token 同 purpose=tokens 表不可区分,subject 级吊销必然连带)或 reset token 追踪落库(违反零迁移);业界标准形态本就是多枚一次性链接并存,爆炸半径由 AE6 收敛。

---

## Planning Contract

### Key Technical Decisions

- KTD1. 用 AshAuthentication password 策略原生 `resettable` 扩展,不自研 token 流。自动生成 `request_password_reset_with_password` / `password_reset_with_password` action;token 为 JWT(jti 存现有 tokens 表),零 schema 变更、零迁移。
- KTD2. reset token 有效期 24 小时。(session-settled: user-approved — chosen over 30min–1h: 国内邮箱转投延迟长,短时效易误伤;每枚一次性 + 重置成功后全吊销兜底安全性)
- KTD3. SendCloud 走普通发送 API `POST https://api.sendcloud.net/apiv2/mail/send`(form-urlencoded,`apiUser/apiKey/from/to/subject/html`),以自定义 Swoosh adapter(内部用已有 Req)接入 `Cgc2046.Mailer`。不引 SMTP/gen_smtp,不新增依赖。前提:apiUser 支持普通发送——上线前与运营确认;若不支持则升级为阻塞问题再决策(模板模式 `/apiv2/mail/sendtemplate` 需运营在控制台建模板并审核、adapter 走 xsmtpapi 独立分支,不是无缝 fallback)。(session-settled: user-approved — chosen over SMTP 与第三方 SDK: 一个 HTTP POST 不值得新依赖)
- KTD4. 防枚举机制分两面。内容面:采用 AshAuthentication 官方语义(用户不存在时静默成功、不调 sender),GraphQL 恒 `sent: true`。时间面:sender 的 SendCloud 外呼经 `Task.start` fire-and-forget 发出,不进入请求路径——已注册邮箱的请求不再比未注册邮箱多一次同步网络往返(timing 枚举主差异源);残余差异(已注册路径 token INSERT + JWT 签名的写/CPU 开销)不做恒时化,已接受。发送失败吞错 + `Logger.warning` + telemetry `[:cgc2046, :password_reset, :send_email]`;`Task.start` 的节点崩溃丢失窗口(毫秒级)同样已接受,仅 telemetry 可见。告警载荷约束:reason 类别 + email 掩码(如 `a***@x.com`),禁止明文 token、重置链接、完整 email、SendCloud 响应原文。实现 R2, R7。
- KTD5. 重置成功后吊销全部会话:用 AshAuthentication 4.14 自带 `log_out_everywhere` add-on(`apply_on_password_change?` 挂到密码变更,内部 `revoke_all_stored_for_subject` 原子 bulk_update,含全部 purpose="user" token 即含其余未用 reset token),不手写逐个 `revoke_jti` 循环。失败语义 fail-closed:吊销在 after_action 内执行,失败则错误冒泡、整个改密事务回滚(action 返回 error)——不存在「密码已改但吊销失败仍 ok:true」的中间态;GraphQL 层捕获该错误后 `Logger.warning` + telemetry `[:cgc2046, :password_reset, :revoke]`(载荷约束同 KTD4)并返回统一重置失败错误,用户可重试(token 未被消耗)。实现 R5。
- KTD6. 不加 `email_verified_at` 字段:系统当前无任何消费「已验证」状态的逻辑,reset 成功已事实证明邮箱所有权(关联 KD1)。(session-settled: user-approved — chosen over 加字落地: 无消费方的 schema 是投机;等首个真实消费方出现再加,迁移成本不变)
- KTD7. 邮件 HTML 直传且双重规避注入:内容避免 `%` 字符(SendCloud 模板变量语法;JWT 为 base64url 不含 `%`);全部插值(email、链接、web_base_url)经 HTML 转义——email 正则允许 `<>"` 等字符,用户可控值不转义即注入邮件 HTML;邮件不渲染 display_name。
- KTD8. 滥用防护为三个限流维度(全部走现有 ETS RateLimit 机制,无吊销耦合):RateLimit 增加 `normalize`(归一值进 key)与 `window_seconds`(缺省 900,现有调用方零变化)两个可选选项;email-only 全局层与 IP-only 跨邮箱层由 resolver 以独立 key 直调 `RateLimit.check/1` 实现(前者 key 无 IP 前缀 + 3600s 窗口,后者 key 无 email 值 + 3600s 窗口)。实现 R6。

### High-Level Technical Design

```mermaid
sequenceDiagram
    participant W as web (Next.js)
    participant G as GraphQL (graphql_schema.ex)
    participant AA as AshAuthentication resettable + log_out_everywhere
    participant S as SendPasswordResetEmail (sender)
    participant M as Swoosh adapter → SendCloud

    W->>G: requestPasswordReset(email)
    G->>G: 归一化 email → RateLimit 三层(IP+email 15min/5;email 1h/5;IP 跨邮箱 1h/20)
    G->>AA: request_password_reset_with_password
    alt 邮箱存在
        AA->>S: send(user, reset_token)
        S->>M: Task.start fire-and-forget: Mailer.deliver(重置链接)
        Note over M: 外呼不在请求路径(KTD4 timing 面)
        M-->>S: 异步 {:ok,_} / {:error,_}(吞错+telemetry,载荷掩码)
    end
    G-->>W: { sent: true }(恒定,响应时间无外呼差异)

    W->>G: resetPassword(resetToken, password)
    G->>G: RateLimit(IP+token, 15min/5)
    G->>AA: Strategy.action(:reset)(Jwt.verify → user → update)
    alt 改密+吊销同事务成功
        AA->>AA: log_out_everywhere: revoke_all_stored_for_subject
        AA-->>G: {:ok, user}(全部 token 已吊销)
        G-->>W: { ok: true }
    else token 失效类
        G-->>W: error「链接无效或已过期」invalid_reset_token
    else 密码不合规
        G-->>W: error 指向 password 字段(token 未消耗)
    else 吊销失败(fail-closed)
        AA-->>G: {:error}(事务回滚,token 未消耗)
        G->>G: Logger.warning + telemetry :revoke(告警)
        G-->>W: error 统一重置失败(可重试)
    end
```

组件边界:adapter 只管 HTTP 与配置;sender 只管邮件内容、转义与异步外呼;GraphQL 层只管归一化、限流、action 调用与错误分类;吊销由 log_out_everywhere 在改密事务内完成;前端只管表单与文案。

### Assumptions

- SendCloud 账户已有 API_USER / API_KEY,发信域名已配 DKIM/SPF;apiUser 支持普通发送(不支持则按 KTD3 升级为阻塞问题)。联调前由运营提供凭证,阻塞生产发信、不阻塞实现。
- 生产 web 域名经 `WEB_BASE_URL` 提供(拼重置链接);dev 默认 `http://localhost:3000`;prod 强制 https(非 https raise,防 token 明文过网)。
- 单节点 ETS 限流与现有登录限流同构,不因找回流程扩容;若未来多节点部署,email-only/IP-only 全局层按节点数放大,届时换 Redis(现有 rate_limit.ex 注释已声明此边界)。

### Open Questions

- `SENDCLOUD_FROM` 发件地址与 `WEB_BASE_URL` 生产值:运营在部署时定,非阻塞(Deferred)。
- 邮件文案终稿:实现用初稿(信息要件见 U2),后续可改,非阻塞(Deferred)。
- 部署平台/Vercel/反代 access log 对 query string 的记录与脱敏策略:`?token=` 服务端落日志面需部署层确认(前端已 replaceState + no-referrer),非阻塞(Deferred,部署时核对)。
- 已登录用户访问 `/forgot-password`、`/reset-password`:默认放行(跟随现有 login/register 页不重定向的惯例);如需重定向再迭代。
- `next` 参数不贯穿找回链路(找回成功后跳 `/login` 不带 next,用户重新找入口);如报名转化数据证明流失明显再补透传。

### Sources

- AshAuthentication `resettable` DSL(sender/token_lifetime/action 命名):`backend/deps/ash_authentication/documentation/dsls/DSL-AshAuthentication.Strategy.Password.md`
- `log_out_everywhere` add-on(apply_on_password_change? / revoke_all_stored_for_subject / after_action 失败回滚):`backend/deps/ash_authentication/lib/ash_authentication/add_ons/log_out_everywhere/`
- `Strategy.action(:reset)` 官方入口(Jwt.verify→subject_to_user→for_update):`backend/deps/ash_authentication/lib/ash_authentication/strategies/password/strategy.ex`
- reset token 与会话 token 同为 purpose="user"(act claim 不落库):`backend/deps/ash_authentication/lib/ash_authentication/strategies/password.ex` reset_token_for
- 密码 min_length: 8(自动生成 action 的 constraints):`backend/deps/ash_authentication/lib/ash_authentication/strategies/password/transformer.ex`
- SendCloud 发送 API 参数与返回:`https://www.sendcloud.net/doc/email_v2/send_email/`
- 现有手写 auth mutation 惯例:`backend/lib/cgc_2046_web/graphql_schema.ex`(signIn/signUp);token 类公开 mutation 限流惯例(同文件 accept_invitation,`key_path: [:input, :token]`)
- 限流中间件:`backend/lib/cgc_2046_web/plugs/rate_limit.ex`(Absinthe middleware,ETS 固定窗口 15min 硬编码,key 含 REMOTE_IP——本计划参数化)
- dev 邮箱预览挂载点 `/mailbox`(非 /dev/mailbox):`backend/lib/cgc_2046_web/router.ex`

---

## Implementation Units

### U1. SendCloud Swoosh adapter 与 Mailer 生产配置

- **Goal**:生产环境 `Cgc2046.Mailer` 经自定义 adapter 调 SendCloud 普通发送 API;dev/test 行为零变化。
- **Requirements**:R7
- **Dependencies**:无(与 U2 可并行)
- **Files**:
  - `backend/lib/cgc_2046/swoosh_adapters/send_cloud.ex`(新)
  - `backend/config/runtime.exs`(改:prod 块 Mailer adapter 配置 + `WEB_BASE_URL` https 校验,缺 env/非 https 时 raise,模式同 `CORS_ORIGIN`)
  - `backend/test/cgc_2046/swoosh_adapters/send_cloud_test.exs`(新)
- **Approach**:
  1. adapter 实现 Swoosh.Adapter `deliver/2`:从 email 结构取 `to/subject/html_body`,从 config 取 `api_user/api_key/from/from_name`,`Req.post` form 编码到 `/apiv2/mail/send`,按 `{"result": true}` 判定成败。
  2. runtime prod 块读 `SENDCLOUD_API_USER/SENDCLOUD_API_KEY/SENDCLOUD_FROM/SENDCLOUD_FROM_NAME` 与 `WEB_BASE_URL`,缺失或 `WEB_BASE_URL` 非 https 时 raise;非 prod 保持 `Swoosh.Adapters.Local`/`Test`(现有 config 不动)。
- **Patterns to follow**:Swoosh 内置 API adapter 的 deliver 形状(如 `Swoosh.Adapters.Mailgun`);runtime env 校验模式(`backend/config/runtime.exs` CORS_ORIGIN 块)。
- **Test scenarios**:
  - 成功:SendCloud 返回 `result: true` → `deliver` 返回 `{:ok, map}`(HTTP 用 Req 测试桩拦截)。
  - 失败:返回 `result: false` 或 HTTP 5xx/超时 → 返回 `{:error, reason}`,不抛异常。
  - 参数组装:请求体含 apiUser/apiKey/from/to/subject/html,from 取自 config(KTD3)。
- **Verification**:`mix test test/cgc_2046/swoosh_adapters/send_cloud_test.exs` 绿;dev 环境 `/mailbox` 行为不变。

### U2. User 资源 resettable + log_out_everywhere 与重置邮件 sender

- **Goal**:password 策略挂 `resettable` 与 `log_out_everywhere` add-on,生成 reset action 与改密事务内全吊销;sender 组安全 HTML 邮件并异步外呼。
- **Requirements**:R2, R3, R5, R7, R8
- **Dependencies**:无(U1 可并行;单测用 `Swoosh.Adapters.Test` 不依赖 SendCloud)
- **Files**:
  - `backend/lib/cgc_2046/accounts/user.ex`(改:resettable、log_out_everywhere、policies)
  - `backend/lib/cgc_2046/accounts/send_password_reset_email.ex`(新)
  - `backend/test/cgc_2046/accounts/password_reset_test.exs`(新)
- **Approach**:
  1. `strategies > password` 内加 `resettable do sender ... token_lifetime {24, :hours} end`;`add_ons` 挂 `log_out_everywhere`(apply_on_password_change?)——改密事务内全吊销,含其余未用 reset token;吊销失败整体回滚(KTD1, KTD2, KTD5)。
  2. policies 按现有惯例给 `request_password_reset_with_password` / `password_reset_with_password` 加 bypass(参照 register/sign_in 两条)。
  3. sender 模块:调 `Mailer.deliver`,邮件含 `{web_base_url}/reset-password?token=...`;插值全部 HTML 转义、不渲染 display_name、正文不含 `%`(KTD7);外呼经 `Task.start` fire-and-forget,失败吞错 + `Logger.warning` + telemetry `[:cgc2046, :password_reset, :send_email]`,告警载荷按 KTD4 约束(reason 类别 + email 掩码,禁 token/链接/完整 email)。
  4. `web_base_url` 走 application env(runtime 可配),不硬编码。
  5. 邮件初稿信息要件(终稿可迭代,要件不可缺):链接 24 小时内有效、一次性使用、若非本人操作请忽略本邮件、发件方身份标识。
- **Patterns to follow**:user.ex 现有 policies bypass 块;NotificationFanout 的 telemetry 埋点形状。
- **Test scenarios**:
  - 存在用户:调 `request_password_reset_with_password` → 成功;异步等待后 mailer 收到 1 封含 token 链接的邮件,收件人为该邮箱(fire-and-forget 下需同步等待桩,如轮询 Test adapter 进程邮箱)。Covers AE1 反面。
  - 不存在用户:同 action → 成功(`:ok`),mailer 收到 0 封。Covers AE1。
  - 多链接并存:同一用户二次请求 → 两枚 reset token 均有效(各自可发起重置)。Covers R3 前半。
  - token 重置:以一枚 reset token 调 `password_reset_with_password` + 合规新密码 → 密码更新,新密码可登录,该用户其余全部 token(含另一枚未用 reset token)被吊销。Covers AE4, AE6(资源层)。
  - token 一次性:同一 token 二次使用 → 失败。Covers AE3(资源层)。
  - 过期/伪造 token → 失败,错误不区分「过期/已用/伪造」。
  - 吊销失败 fail-closed:注入吊销失败桩(如 tokens 表写失败)→ 整个 action 失败回滚、密码未变、token 未消耗,telemetry `[:cgc2046, :password_reset, :revoke]` 记录 error。Covers R5。
  - 密码短于 8 位 → 校验失败指向 password,token 未被消耗(再次以合规密码提交仍成功)。Covers R8。
  - XSS 转义:display_name 含 `<img onerror>` 的用户(或构造含 HTML 字符的 email)请求重置 → 邮件 HTML 中该串以转义形态出现。Covers KTD7。
  - 告警载荷:sender 发信失败(Mailer 配置为报错桩)→ action 仍成功,telemetry 记录 error,事件载荷不含明文 token 与完整 email(掩码形态)。Covers AE2。
- **Verification**:`mix test test/cgc_2046/accounts/password_reset_test.exs` 绿;`mix precommit` 编译无警告。

### U3. GraphQL mutations:请求重置与执行重置

- **Goal**:暴露 `requestPasswordReset` / `resetPassword`,归一化 + 三层限流,错误按类分流。
- **Requirements**:R2, R4, R5, R6, R8
- **Dependencies**:U2
- **Files**:
  - `backend/lib/cgc_2046_web/graphql_schema.ex`(改:两个 mutation + 结果类型;`priv/graphql/schema.graphql` 由 `generate_sdl_file` 自动更新,不手改)
  - `backend/lib/cgc_2046_web/plugs/rate_limit.ex`(改:增加可选 `normalize` 与 `window_seconds` 选项;公开无 IP 前缀 key 构造供 resolver 直调)
  - `backend/test/cgc_2046_web/graphql_password_reset_test.exs`(新)
- **Approach**:
  1. `field :request_password_reset`:arg `email`;进入限流前归一化(downcase+trim),三层限流(KTD8):`middleware(RateLimit, key_path: [:email], normalize: ...)` 走 IP+email 层,resolve 内再以独立 key 直调 `RateLimit.check/1` 过 email-only 每小时层与 IP-only 跨邮箱每小时层;任一层超限返回 rate_limited 错误;resolve 调 read action,任何结果恒 `{:ok, %{sent: true}}`(R2,KTD4)。
  2. `field :reset_password`:args `resetToken/password`,`middleware(RateLimit, key_path: [:reset_token])`(对齐 invitation token 限流惯例);resolve 经 `AshAuthentication.Strategy.action(strategy, :reset, %{reset_token: ..., password: ...})` 官方入口调用(内部 Jwt.verify → subject_to_user → for_update → 用后吊销),会话吊销由 U2 的 log_out_everywhere 在改密事务内完成(KTD5);错误分流:token 失效类(过期/已用/伪造)统一 `{:error, message: "链接无效或已过期", code: "invalid_reset_token"}`(R4);密码约束类按 sign_up 错误协议透出 password 字段(R8,token 不被消耗);吊销失败类按 KTD5 告警后返回统一重置失败错误(token 未消耗,可重试)。
- **Patterns to follow**:`signIn` mutation 的 RateLimit + 错误收敛形状;invitation 字段的限流惯例(accept_invitation,`key_path: [:input, :token]`);sign_up 的字段级错误协议;`graphql_*_test.exs` 的请求级测试惯例。
- **Test scenarios**:
  - 请求重置(存在用户):返回 `sent: true`,邮件异步发出。Covers AE1 反面。
  - 请求重置(不存在用户):返回 `sent: true`,无邮件。Covers AE1。
  - IP+email 层限流:同 email 第 6 次请求被拒(15 分钟窗口)。
  - 归一化:`a@x.com` 与 `A@X.COM` 共享同一配额,变体第 6 次被拒。Covers AE5。
  - email-only 层限流:同 email 换 IP 累计第 6 次/小时被拒。Covers AE5。
  - IP-only 跨邮箱层限流:同 IP 对 21 个不同邮箱请求,第 21 个被拒。Covers R6。
  - 重置成功:有效 token + 合规新密码 → `ok: true`;旧密码 signIn 失败、新密码 signIn 成功;该用户此前签发的 bearer token 调 `me` 等 query 返回 401;以小程序策略签发的该用户 token 同样 401(两端吊销);该用户另一枚未用 reset token 再调 resetPassword 返回「链接无效或已过期」。Covers AE3, AE4, AE6。
  - token 失效类:无效/过期/已用 token 统一同一错误消息与 code。Covers AE3。
  - 密码约束类:有效 token + 7 位密码 → 错误指向 password 字段而非 invalid_reset_token;同 token 再用合规密码仍成功。
  - 吊销失败 fail-closed:注入吊销失败 → 统一重置失败错误 + telemetry `:revoke` 记录,token 未消耗(同 token 重试成功)。Covers R5。
  - resetPassword 限流:同 token 第 6 次被拒。
  - 未认证可达:两个 mutation 无需登录态即可调用(policies 放行后)。
- **Verification**:`mix test test/cgc_2046_web/graphql_password_reset_test.exs` 绿;SDL 重新生成且 web 端无 introspection 断言冲突;`rate_limit.ex` 现有调用方(signIn/signUp/invitation)行为不变(normalize/window_seconds 缺省不启用,窗口仍 900s)。

### U4. 前端找回密码页面与登录入口

- **Goal**:`/forgot-password`、`/reset-password` 两个页面 + 登录页入口,反馈文案满足防枚举一致性,token 不残留于 URL,无死胡同状态。
- **Requirements**:R1, R2, R4, R8
- **Dependencies**:U3
- **Files**:
  - `web/app/(auth)/forgot-password/page.tsx`(新)+ `page.test.tsx`(新)
  - `web/app/(auth)/reset-password/page.tsx`(新)+ `page.test.tsx`(新)
  - `web/app/(auth)/login/auth-form.tsx`(改:登录态加「忘记密码?」链接;导出 PasswordField/PasswordStrength 供 reset 页复用)
  - `web/lib/graphql/auth.ts`(改:`REQUEST_PASSWORD_RESET` / `RESET_PASSWORD` mutation 与错误提取)
- **Approach**:
  1. forgot 页:复用 `auth-shell`,单个 email 输入。状态机:提交中(busy,提交按钮禁用 + `aria-busy`,复用 login 提交按钮模式);成功态(表单切换为成功面板「若该邮箱已注册,重置链接已发送」,R2 统一文案,同一会话内不再重复提交);错误态二类——rate_limited 显示「请求过于频繁,请稍后再试」、网络/服务异常显示通用失败可重试,均如实呈现、不伪装成功文案(限流 key 为归一化 email,与注册状态无关,不构成枚举面)。
  2. reset 页:客户端读出 `?token=` 后立即 `history.replaceState` 清除 query(防 Referer/历史泄露);页面输出 `<meta name="referrer" content="no-referrer">`;页面刷新导致 token 丢失落入无 token 无效态(已接受行为:token 未消耗,可从邮件重新进入)。状态机:无 token/无效态——「链接无效或已过期」+ 两条出口(「重新发送重置邮件」链接至 `/forgot-password`、「返回登录」),不是死胡同;表单态(密码 + 确认密码,复用 PasswordField/PasswordStrength,前端提示 min 8;提交中禁用按钮防 token 一次性误耗);token 失效类错误原样呈现「链接无效或已过期」+ 重新申请入口(R4),密码约束类错误指向密码字段(R8);成功态——成功面板(含「为安全起见,你已在所有设备(含小程序)退出登录」告知,R5)+「去登录」按钮手动跳转(不自动 redirect)。
  3. login 表单登录模式加「忘记密码?」链接至 `/forgot-password`(仅登录 mode)。
  4. a11y:成功/无效/错误态切换后焦点移至状态提示区,提示区用 `role="status"`(成功/无效)/ `role="alert"`(错误),对齐 login 页 auth-alert 惯例;响应式由 auth-shell 布局覆盖,无新增工作。
- **Patterns to follow**:`web/app/(auth)/login/` 的页面结构、`use-auth-submit` 的错误提取调用方式、`auth-next.test.ts` 的 mutation 测试惯例。
- **Test scenarios**:
  - forgot 提交:调 mutation,成功后显示统一文案,不区分邮箱是否注册。Covers AE1(前端面)。
  - forgot 错误态:rate_limited 错误 → 显示「请求过于频繁」而非成功文案;提交中按钮禁用。
  - reset 无 token:渲染无效链接态(含「重新发送」与「返回登录」两条出口),不调 mutation。
  - reset 读 token:token 读出后 URL 不再含 token(replaceState 生效)。
  - reset 成功:有效 token + 合规密码 → 成功面板(含全端登出告知)+「去登录」;token 失效错误 → 「链接无效或已过期」+ 重新申请入口。Covers AE3, R4(前端面)。
  - reset 密码不一致/短于 8:前端校验拦截,不发请求(R8);后端密码字段错误可呈现;提交中按钮禁用。
  - login 页:登录模式渲染「忘记密码?」链接,注册模式不渲染。
- **Verification**:`pnpm test`、`pnpm typecheck` 绿。

### U5. 端到端验证(dev 全流程)

- **Goal**:dev 环境用 `/mailbox` 走通全链路,按 AGENTS.md 分层断言固化行为证据。
- **Requirements**:R1–R8
- **Dependencies**:U1, U2, U3, U4
- **Files**:无新文件;验证记录附 PR 描述。
- **Approach**:
  1. 起 dev 后端(Email Local adapter)+ web dev。
  2. agent-browser 结构断言:login 页「忘记密码?」链接存在;forgot 页提交注册邮箱 → 统一成功文案。
  3. `/mailbox` 取重置邮件,提取链接。
  4. 走 reset 页:提交新密码 → 成功;URL 中 token 已被清除;旧密码登录失败 + 新密码登录成功(交互断言)。
  5. 反向断言:提交未注册邮箱,页面文案与已注册邮箱完全一致(AE1);两枚链接场景:二次请求得第二枚,用其一重置成功后另一枚失效(AE6)。
  6. 截图作为人工复核证据(结构断言已过后仅留档)。
- **Patterns to follow**:AGENTS.md「E2E 验证」分层约定(结构/样式断言为主,视觉模型兜底)。
- **Test scenarios**: Test expectation: none — 验证单元,产出为 PR 内行为证据,不新增自动化测试。
- **Verification**:PR 描述含各步断言结果;无一步靠「看起来对」替代数值/文本断言。

---

## Verification Contract

| 门禁 | 命令 | 适用 |
|---|---|---|
| 后端测试 | `mix test`(backend/) | 全部后端 unit |
| 后端质量 | `mix precommit`(compile --warnings-as-errors + format + test) | 合并前 |
| 前端测试 | `pnpm test`(web/) | U4 |
| 前端类型 | `pnpm typecheck`(web/) | U4 |
| E2E | agent-browser 按 U5 步骤 | U5(dev 环境) |
| 依赖合规 | `mix cgc2046.check_licenses` + `pnpm check:licenses` | 必须通过(本计划零新增依赖,应天然通过) |

---

## Definition of Done

- R1–R8 全部满足;AE1–AE6 各自被至少一条自动化断言覆盖(U2/U3/U4 测试),安全加固断言齐:大小写限流归一、跨 IP 全局预算、IP 跨邮箱预算、重置成功全吊销(含小程序端)、吊销失败 fail-closed 告警、弱密码错误分类且 token 不消耗、URL token 清除、邮件 HTML 转义、告警载荷掩码。
- 验证合同全部门禁绿;U5 E2E 证据附 PR。
- `rate_limit.ex` 的 normalize/window_seconds 选项不改变现有调用方(signIn/signUp/invitation)行为(缺省路径窗口仍 900s)。
- 零新增 hex/npm 依赖、零数据库迁移(schema 快照无 diff)。
- 实验与死代码清除:无临时 token 打印、无被注释的备选发送路径、无未使用模块。
- 邮件初稿含 U2 信息要件(24h/一次性/非本人忽略/发件身份);生产部署所需 env(`SENDCLOUD_API_USER/SENDCLOUD_API_KEY/SENDCLOUD_FROM/SENDCLOUD_FROM_NAME/WEB_BASE_URL`)在 runtime 缺失或 `WEB_BASE_URL` 非 https 时给出明确 raise 提示,已写入部署说明或 PR 描述。
