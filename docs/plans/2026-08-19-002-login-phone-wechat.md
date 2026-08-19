# Plan 2026-08-19-002 · 登录升级：手机号/邮箱密码 + 手机验证码 + 微信扫码

## 背景

web 端登录仅支持 email+password(`web/lib/graphql/auth.ts` SIGN_IN/SIGN_UP,`backend/lib/cgc_2046_web/graphql_schema.ex:399-440`)。目标对齐参考截图：手机号/邮箱 + 密码单框登录、手机验证码登录、微信扫码登录。

取证基础（2026-08-19 三路 scout,HEAD):

- `users.phone` 字段与部分唯一索引**已存在**（迁移 `20260808130100`,user.ex:62-65,364)，小程序登录已用手机号锚定 find-or-create，归一化格式 `+区号号码`(`miniprogram/client.ex:662-672`)。
- JWT 经 httpOnly cookie `cgc_token` 交付（`auth_cookie_plug.ex`),TTL 7d；重登吊销旧 token 已有先例（`sign_in_preparation.ex`)。
- RateLimit ETS 中间件可配置窗口/次数（密码重置双限流先例 graphql_schema.ex:1548-1568)。
- **零验证码机制、零 SMS 能力、零网站 OAuth**。SendCloud 邮件 adapter 是 Req 直调先例（`swoosh_adapters/send_cloud.ex`);wechat_sdk `WeChat.WebPage.code2access_token` 端点与开放平台网站应用相同，但 qrconnect URL SDK 不产（`deps/wechat/.../web_page.ex:112-138` 只产公众号 `connect/oauth2/authorize`)。

## 决策（用户 2026-08-19 已拍板）

1. **微信扫码**:按完整实现做，凭证（开放平台网站应用 AppID/Secret）用户去申请；代码按可配置门禁落地，凭证缺失时该功能不可用但不崩（`provider_not_configured` 模式，支付先例 wechat_pay.ex:173-188)。
2. **未绑定微信扫码** → 强制手机号验证码完成绑定/建号。
3. **SMS 接入**:SendCloud `smsapi/send` 模板端点（模板需控制台审核，运营前置）。
4. **手机验证码登录**:用户不存在时自动建号（与小程序 find-or-create 一致）。

### 关键技术决策（orchestrator 定，依据取证）

- **D1 微信换码走 Req 直调，不走 SDK client**。先例：小程序 code2session 就是 Req 直调（`miniprogram/client.ex:62-70`);OfficialAccount client 可能自动注入 access_token / 启动 refresher(网站应用无 client_credential 能力），行为不确定。三个端点全部 Req:`/sns/oauth2/access_token`、`/sns/userinfo`、手拼 `https://open.weixin.qq.com/connect/qrconnect?...`。
- **D2 扫码交互用 iframe 嵌入 qrconnect URL**（微信官方标准做法）。用户确认后微信将**顶层窗口**重定向到 `redirect_uri?code=&state=`。**不用** `qrcode` 库自渲染 qrconnect URL（那会让重定向发生在手机里，桌面端登录断链）。
- **D3 新登录方式不做 AshAuthentication 自定义 strategy 插件**。miniprogram strategy 的 routes 机制未被接线（router.ex 无认证 REST 路由），插件骨架是无效开销。改为普通 Ash action + 手写 GraphQL resolver（现有 signIn 同款），复用 SignInPreparation 内部模式。
- **D4 `signIn` 入参 `email` → `login`**(clean cutover，自动识别 @→email 否则按手机号归一化）。唯一调用方是 web(`web/lib/graphql/auth.ts`)，同 PR 更新。小程序用 signInWithPlatform 不受影响。
- **D5 手机号归一化抽取共享模块** `Cgc2046.Accounts.PhoneNumber`,`miniprogram/client.ex:662-672` 改为委托（禁止第二套归一化，防同号分裂 +86138 vs 138)。
- **D6 验证码与微信 ticket 全部 DB 持久化**（新 Ash 资源），不用 ETS——天然跨重启、原子消费走 DB 约束，清理靠 expires_at + 定期任务（后续可接 Oban pruner,v1 手动/懒清理）。

## 实施单元（backend + web，单 PR)

### U1 手机号归一化共享模块（backend)

1. 新增 `Cgc2046.Accounts.PhoneNumber.normalize/1`：入参任意字符串，产出 `+区号号码` 或 `{:error, :invalid}`；逻辑= `miniprogram/client.ex:662-672` 现状（默认 +86)。
2. `miniprogram/client.ex` 删除原私有实现，改为委托 `PhoneNumber.normalize/1`；全部既有 callsite 同步。
3. 单测：normalize 边界（带/无区号、空格、横线、非法字符、超长）。

### U2 手机号+密码登录（backend)

1. user.ex strategies 增第二 password 策略：
   ```elixir
   password :password_phone do
     identity_field(:phone)
     confirmation_required?(false)
   end
   ```
   仅消费其 `sign_in_with_password_phone` action;**不开放** `register_with_password_phone`(GraphQL 不暴露）。
2. policies 增 `bypass action(:sign_in_with_password_phone)`（仿 user.ex:398-401 前例）。
3. `signIn` resolver(graphql_schema.ex:399-440）改造：入参 `email: String!` → `login: String!`；含 `@` 走原 `sign_in_with_password`，否则 `PhoneNumber.normalize` 后走 `sign_in_with_password_phone`。错误统一 `{message, code: "authentication_failed"}`（防枚举，现状语义不变）。RateLimit key_path 改 `[:login]`。
4. `priv/graphql/schema.graphql` 同步。
5. 测试：手机号登录成功/失败、email 回归、未归一化输入（`138…` vs `+86138…` 同号）、限流挂载点。

### U3 SendCloud SMS + 手机验证码登录（backend)

1. **SMS 发送模块** `Cgc2046.Sms.SendCloud`（新文件，**不进 Swoosh**——SMS 非邮件）:
   - `send_template_sms(phone, template_id, vars, send_request_id) :: :ok | {:error, term()}`;
   - `POST https://api.sendcloud.net/smsapi/send`，参数 `smsUser/templateId/phone/vars(JSON 串)/signature/timestamp/sendRequestId`;
   - 签名：参数（除 signature/smsKey）按 key 字典序拼 `k=v&…`，前后包 SMS_KEY,SHA256 hex（官档 https://www.sendcloud.net/doc/sms/ §API 验证机制）;
   - Req 实现 + `req/1` helper 同款（`miniprogram/client.ex:680-687`),test 经 `config :cgc_2046, :sms_req_plug` 注入 `{Req.Test, stub}`(test.exs 先例）;
   - 配置：prod 必须（缺则 raise，邮件先例 runtime.exs:238-272）新增 `SENDCLOUD_SMS_USER` / `SENDCLOUD_SMS_KEY` / `SENDCLOUD_SMS_TEMPLATE_ID`;dev/test dummy(config.exs 先例）;dev 环境未配置时 Logger 输出验证码（本地可测）。
2. **验证码资源** `Cgc2046.Accounts.PhoneVerificationCode`（表 `phone_verification_codes`):
   - 字段：`phone, code_hash(sensitive), purpose(:login|:wechat_bind), expires_at(5min), attempts_left(3), consumed_at, send_request_id`;
   - 创建：6 位数字码（`:crypto.strong_rand_bytes` 取模），只存 `SHA256(phone <> ":" <> code)`;
   - 消费：**原子**「校验+attempts-1+置 consumed」（DB 层 `WHERE id AND consumed_at IS NULL AND attempts_left > 0 AND expires_at > now()` 单次 UPDATE，防并发重放）;
   - 发新码作废旧活跃码（phone+purpose 未消费全置 consumed)。
3. **登录流程模块** `Cgc2046.Accounts.PhoneCodeSignIn`：验码 → find-or-create User by phone（复用/抽取 `sign_in_preparation.ex` 的 find_or_create/race-retry/默认工作台入座）→ 吊销旧 token → 签 JWT（无 platform claim)。共享助手抽到 `Cgc2046.Accounts.SignInFlow`,miniprogram 的 SignInPreparation 同步改为调用它（clean cutover，不留第二份）。
4. **GraphQL**:
   ```graphql
   requestPhoneCode(phone: String!, purpose: PhoneCodePurpose!): RequestPhoneCodeResult!  # {sent, retryAfterSeconds}
   signInWithPhoneCode(phone: String!, code: String!): SignInResult!
   ```
   - 限流：requestPhoneCode = phone 1/60s + 5/1h + 20/1day,IP 30/1day;signInWithPhoneCode = phone 5/15min + IP 20/15min（复用 RateLimit 多实例挂载，密码重置双限流先例）。
   - 发码统一返回 `sent: true`（含 SendCloud 失败外的所有分支；SendCloud 5xx/超限返回 sent:false + retryAfterSeconds)。
   - 错误码：`invalid_or_expired_code`（统一，不区分不存在/过期/错码，防枚举）。
5. 测试：发码限流各窗口、码过期、3 次错失效、单次使用、并发消费防重放、自动建号、重登吊销旧 token、SendCloud 签名计算（官档示例向量）、配置缺失门禁。

### U4 微信扫码登录（backend)

1. **配置**:prod 可选门禁（缺=`:wechat_web_not_configured`,wechat_pay 先例）新增 `WECHAT_WEB_APPID` / `WECHAT_WEB_SECRET`;`redirect_uri` = `:web_base_url` + `/login/wechat-callback`(runtime.exs 既有 web_base_url :31-46)。dev/test dummy。
2. **HTTP 层** `Cgc2046.OAuth.WechatWeb`(Req 直调，D1):
   - `qr_connect_url(redirect_uri, state) :: String.t()` —— 手拼 `https://open.weixin.qq.com/connect/qrconnect?appid=..&redirect_uri=..(urlencode)&response_type=code&scope=snsapi_login&state=..#wechat_redirect`;
   - `code2access_token(code) :: {:ok, %{openid, unionid, access_token}} | {:error, term()}`;
   - `user_info(openid, access_token)`（取 nickname,可选用于 display_name)。
3. **Ticket 资源** `Cgc2046.Accounts.WechatLoginTicket`（表 `wechat_login_tickets`):`state(uuid, 唯一), openid, unionid, access_token(sensitive), status(:pending|:needs_binding|:consumed|:expired), expires_at(10min)`。state 单次使用、过期作废；消费原子 UPDATE。
4. **登录流程** `Cgc2046.Accounts.WechatWebSignIn`:
   - `sign_in_with_wechat(code, state)`：验 state → 换 token → UserIdentity 查找顺序 ①(provider `:wechat_web`, uid=openid)②unionid 匹配任意 wechat 系 identity → 命中：消费 ticket、吊销旧 token、签 JWT → `:signed_in`；未命中：ticket 落 openid/unionid/access_token 转 `:needs_binding` 返回 bindTicket(=state)。
   - `bind_wechat_with_phone(bindTicket, phone, code)`：验 ticket(needs_binding+未过期）→ 验 phone code(purpose :wechat_bind)→ find-or-create User(SignInFlow)→ upsert UserIdentity(provider :wechat_web, uid openid, unionid)→ 消费 ticket → 签 JWT。
5. **UserIdentity.provider 枚举扩展**:`one_of` 增 `:wechat_web`(user_identity.ex;attribute 层约束，确认无 DB CHECK 则免迁移，有则出迁移）。
6. **GraphQL**:
   ```graphql
   wechatLoginStart: WechatLoginStartResult!  # {qrUrl, state, expiresInSeconds};未配置 → 错误码 wechat_login_unavailable
   signInWithWechat(code: String!, state: String!): SignInWithWechatResult!  # {status: SIGNED_IN|NEEDS_BINDING, bindTicket}
   bindWechatWithPhone(bindTicket: String!, phone: String!, code: String!): SignInResult!
   ```
   限流：wechatLoginStart IP 20/15min;signInWithWechat IP 20/15min;bindWechatWithPhone phone 5/15min。
7. 测试：state 单次/过期、code 换 token 失败（Req.Test stub)、identity 命中两条路径、unionid 跨应用合并、绑定全流程、未配置门禁、并发 sign_in 同窗。

### U5 前端登录页（web)

1. **登录页改版**(`app/[locale]/(auth)/`):AuthShell 表单面板改为两栏（左：登录方式区；右：微信扫码卡片，移动端上下堆叠）。参考截图布局，样式复用 `globals.css:1334-1625` `auth-*` 类与 `@theme` token，新增样式写同区块。
2. **账号密码 Tab**:`auth-form.tsx` 输入框 label/placeholder 改「手机号/邮箱地址」，提交走新 `signIn(login, password)`；保留密码可见性、忘记密码、立即注册、`?next=` 全链路保留。
3. **验证码登录 Tab**(`sms-form.tsx` + `use-sms-login.ts`)：手机号输入 + 6 位验证码 + 「获取验证码」按钮（60s 倒计时，参考 payment countdown)；提交 `signInWithPhoneCode`；成功 `client.resetStore()` + `router.push(next)`（对齐 use-auth-submit.ts:73-81)。
4. **微信扫码面板**(`wechat-qr-panel.tsx`)：挂载调 `wechatLoginStart` → iframe 嵌 qrUrl(宽高开微信授权页);`wechat_login_unavailable` 时隐藏整个扫码卡片；`state` 过期给刷新按钮。
5. **回调页** `app/[locale]/(auth)/login/wechat-callback/page.tsx`：读 `?code&state` → `signInWithWechat` → `SIGNED_IN`:resetStore+push(next);`NEEDS_BINDING`：渲染绑定表单（手机号+验证码，`requestPhoneCode(WECHAT_BIND)` + `bindWechatWithPhone`)→ 成功 resetStore+push。
6. **GraphQL 文档**:`web/lib/graphql/auth.ts` 扩展 SEND_PHONE_CODE / SIGN_IN_WITH_PHONE_CODE / WECHAT_LOGIN_START / SIGN_IN_WITH_WECHAT / BIND_WECHAT_WITH_PHONE;SIGN_IN 参数 email→login。
7. **i18n**:`messages/zh-CN.json` + `en.json` `auth.*` 同步双语（check-i18n-keys/coverage 强制）。
8. **测试**(vitest，沿用 vi.hoisted + useMutation 按名 mock 约定）:login 字段识别文案、SMS 倒计时与错误、扫码面板挂载/不可用隐藏、callback 三分支（signed_in / needs_binding / 错误）、绑定表单提交、`?next=` 保留。

## 验收标准

1. 手机号（任意可归一化格式）+ 密码可登录；email 密码登录回归通过；错误统一防枚举。
2. 手机验证码全流程：发码（限流生效）→ 正确码登录（不存在用户自动建号）→ 错码 3 次失效 → 码单次使用 → 重登旧 token 失效。
3. 微信扫码：wechatLoginStart 出码 URL →（Req.Test 拦截）code 换 token → 已绑定直登；未绑定 → 手机号验证 → 建号/绑定 → 登录；state 重放/过期拒绝；未配置返回 `wechat_login_unavailable`。
4. 前端：三方式 UI 结构断言（agent-browser 确定性分层：结构/样式断言优先）；`?next=` 全方式保留；登录后 resetStore 不串用户。
5. backend `mix format --check-formatted` + `mix compile --warnings-as-errors` + `MIX_ENV=test mix test` ×2 seeds 全绿；web `pnpm typecheck && pnpm lint && pnpm test && pnpm build` 全绿。

## 非目标

- Apple 登录（截图有，本次不做）。
- 注册页手机号注册、账号设置里的「设置密码/绑定微信/换绑手机号」页面。
- SMSHook 回调接收（送达回执）、国际短信、语音验证码。
- RateLimit 换 Redis（单节点 ETS 现状维持，rate_limit.ex moduledoc 自述限制）。
- 已丢失 session 兼容：signIn 入参改名对 web 是同 PR cutover，不做双参数兼容期。

## 风险

| 风险 | 缓解 |
|---|---|
| 微信网站应用审核未过/无凭证 | 配置门禁，前端隐藏扫码卡片；其余两方式不受影响 |
| SendCloud 模板未审核/未备案 | 运营前置列 plan；未配置时 dev 打日志、prod 启动 raise（与邮件一致） |
| 验证码成本面被刷 | 四窗口限流（phone 1/min+5/h+20/day、IP 30/day)+ 码只存哈希 + 3 次错失效 |
| openid 跨应用不一致 | UserIdentity 存 unionid,unionid 兜底匹配合并小程序账号 |
| 扫码重定向打断 SPA 状态 | callback 页读 `?next=` 由 state 无关的 URL 参数透传（state 只防伪）;resetStore 后跳转 |
| 手机号明文存储（现状已接受） | 不扩大暴露面：GraphQL 不新增 phone 查询出口 |
| SignInFlow 抽取影响小程序登录 | 抽取后 miniprogram 既有测试全绿为回归证明 |
| ETS RateLimit 多节点失效 | 现状同；plan 不加剧（新限流同机制） |

## 运营前置（人类任务，不阻塞代码合并，阻塞功能上线）

1. SendCloud 控制台：创建 SMS_USER/SMS_KEY（短信语音→发送授权）；提交验证码短信模板审核（含签名）；短信备案。
2. 微信开放平台：企业认证 → 创建网站应用（需 ICP 备案域名）→ 登记授权回调域 → 拿 AppID/AppSecret。
3. 部署 env:`SENDCLOUD_SMS_USER/KEY/TEMPLATE_ID`、`WECHAT_WEB_APPID/SECRET`。

## 关联

- Scout 取证（2026-08-19):`agent://ScoutBackendAuth` / `agent://ScoutIntegrations` / `agent://ScoutFrontend`
- SendCloud SMS 官档：https://www.sendcloud.net/doc/sms/ 、https://www.sendcloud.net/doc/sms/api
- 相关前例：#60(httpOnly cookie)、#214(failed-auth 节流）、ADR-0007（渠道边界 adapter)
