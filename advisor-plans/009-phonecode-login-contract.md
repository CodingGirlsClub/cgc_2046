# Plan 009: 接入 getPhoneNumber 新契约（phoneCode）——微信侧经 SDK `get_phone_number` 直取手机号

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 048c9f8..HEAD -- backend/lib/cgc_2046/accounts/strategies/miniprogram.ex backend/lib/cgc_2046/accounts/strategies/miniprogram/ backend/lib/cgc_2046/miniprogram/client.ex backend/lib/cgc_2046_web/graphql_schema.ex miniprogram/src/api/ miniprogram/src/platform/index.ts miniprogram/src/pages/login/index.tsx`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: advisor-plans/008-miniprogram-wechat-sdk-adoption.md（复用其
  `WechatClient.fetch()`；必须先 DONE 或至少其 WechatClient 模块已合入）
- **Category**: bug / migration
- **Planned at**: commit `048c9f8`, 2026-08-18

## Why this matters

微信新基础库的 `getPhoneNumber` 回调只给动态 `code`（phoneCode），逐步下线
`encryptedData`+`iv`。当前前后端契约**只收 legacy 字段**：前端
`platform/index.ts:38-41` 硬性要求 `encryptedData`/`iv`（`event.detail.code` 成死字段），
后端 action 两个参数 `allow_nil?: false`。真机（现代基础库）登录必然失败——新用户无法
登录。真机清单已挂账（REAL_DEVICE_CHECKLIST N1「phoneCode 契约待 backend 补齐」）。

wechat_sdk 的 `WeChat.MiniProgram.UserInfo.get_phone_number(client, openid, code)`
（deps/wechat/lib/wechat/mini_program/user_info.ex:130，POST
/wxa/business/getuserphonenumber）用 phoneCode 直取手机号，**不经过 session_key**——
同时弱化「session_key 必须在服务端流转」这条安全红线的暴露面（后端不再需要为解密手机号
而持有 session_key）。tt/xhs 无等价 API，保持 legacy 解密路径不变。

## Current state

**后端**（登录链三段）：

1. `backend/lib/cgc_2046/accounts/strategies/miniprogram.ex:85-140` — action 参数在
   `build_sign_in_action/2` 里以 `Transformer.build_entity!` 程序化构建：

```elixir
      Transformer.build_entity!(Resource.Dsl, [:actions, :read], :argument,
        name: :encrypted_data,
        type: :string,
        allow_nil?: false,
        sensitive?: true,
        description: "getPhoneNumber 加密数据"
      ),
      Transformer.build_entity!(Resource.Dsl, [:actions, :read], :argument,
        name: :iv,
        type: :string,
        allow_nil?: false,
        sensitive?: true,
        description: "getPhoneNumber 加密初始向量"
      )
```

2. `backend/lib/cgc_2046/accounts/strategies/miniprogram/sign_in_preparation.ex:44-59`：

```elixir
  defp do_sign_in(query, context) do
    platform = Query.get_argument(query, :platform)
    code = Query.get_argument(query, :code)
    encrypted_data = Query.get_argument(query, :encrypted_data)
    iv = Query.get_argument(query, :iv)

    with {:ok, session} <- Client.code2session(platform, code),
         {:ok, phone} <- Client.decrypt_phone(platform, session, encrypted_data, iv),
         {:ok, user, created?} <- find_or_create_user(phone),
         ...
```

3. `backend/lib/cgc_2046_web/graphql_schema.ex:594-613` — GraphQL 暴露：

```elixir
    field :sign_in_with_platform, :sign_in_with_platform_result do
      arg(:platform, non_null(:string))
      arg(:code, non_null(:string))
      arg(:encrypted_data, non_null(:string))
      arg(:iv, non_null(:string))
      ...
      resolve(fn _,
                 %{platform: platform, code: code, encrypted_data: encrypted_data, iv: iv},
                 _ ->
        query =
          Cgc2046.Accounts.User
          |> Ash.Query.for_read(:sign_in_with_miniprogram, %{
            platform: platform,
            code: code,
            encrypted_data: encrypted_data,
            iv: iv
          })
```

   `backend/lib/cgc_2046/accounts/user.ex:24` 的 moduledoc 同步写着 mutation 形状
   （改契约时一并更新这行）。

**SDK**（勿改）：`WeChat.MiniProgram.UserInfo.get_phone_number(client, openid, code)`
→ `client.post("/wxa/business/getuserphonenumber", %{code: code}, query: [access_token: ...])`；
成功 body `{"errcode": 0, "phone_info": {"phoneNumber", "purePhoneNumber", "countryCode", ...}}`。
client 来自 plan 008 的 `Cgc2046.Miniprogram.WechatClient.fetch/0`（若 008 的模块名不同，
以 008 实际合入为准）。

**前端**：

- `miniprogram/src/platform/index.ts:30-42`（preparePlatformLogin 收尾段）：

```ts
  const login = await Taro.login()
  const encryptedData = phonePayload.encryptedData
  const iv = phonePayload.iv
  if (!login.code || !encryptedData || !iv) {
    throw new Error('手机号授权数据不完整，请重新授权后重试')
  }
  return { ...phonePayload, loginCode: login.code, encryptedData, iv }
```

  `phonePayload` 即 `event.detail`——其中 **`code` 字段已存在但从未被读取**
  （`miniprogram/src/domain/models.ts` 的 `PlatformPhonePayload.code` 是死字段）。
- `miniprogram/src/api/operations.ts:131-141`：`SignInWithPlatform` mutation 变量仅
  `$encryptedData: String!`、`$iv: String!`（无 phoneCode）。
- `miniprogram/src/pages/login/index.tsx:54-59`：`onGetPhoneNumber={(event) => login(event.detail)}`
  ——detail 原样传入，前端无需改这行。
- 类型生成：`miniprogram/` 有 codegen（`pnpm codegen`，codegen.yml 生成
  `src/api/generated/`）；改 operations.ts 后必须重跑并提交生成物（CI 会对比）。
- 测试：`miniprogram/tests/real-auth.test.ts`（vitest 清单内）是登录事务测试的家；
  mock 走 `mockTransport.ts`（按 operation 字符串匹配，兼容旧形状即可）。
- 后端测试桩先例：`backend/test/support/miniprogram_fixtures.ex`（code2session body
  builders + Req.Test 断言 appid/secret 来自 config）；wechat 分支 Tesla.Mock 用法见
  plan 008 Step 4（本计划沿用）。

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 后端编译 | `cd backend && mix compile --warnings-as-errors` | exit 0 |
| 后端测试 | `cd backend && mix test` | 全绿 |
| 前端 codegen | `cd miniprogram && pnpm codegen` | 生成物更新且无 diff 残留 |
| 前端类型 | `cd miniprogram && pnpm typecheck` | exit 0 |
| 前端测试 | `cd miniprogram && pnpm test:unit` | 全绿 |

## Scope

**In scope**:
- `backend/lib/cgc_2046/accounts/strategies/miniprogram.ex`
- `backend/lib/cgc_2046/accounts/strategies/miniprogram/sign_in_preparation.ex`
- `backend/lib/cgc_2046/miniprogram/client.ex`（新增 `fetch_phone_by_code/3` 公开函数）
- `backend/lib/cgc_2046_web/graphql_schema.ex`（仅 sign_in_with_platform field）
- `backend/lib/cgc_2046/accounts/user.ex`（仅 :24 moduledoc 的 mutation 形状行）
- 对应后端测试文件（登录策略测试所在文件 + `test/support/miniprogram_fixtures.ex`）
- `miniprogram/src/api/operations.ts`、`src/api/real.ts`、`src/domain/models.ts`、
  `src/platform/index.ts`、`src/api/generated/**`（codegen 产物）、
  `miniprogram/tests/real-auth.test.ts`

**Out of scope**:
- `decrypt_phone/4` 与 tt/xhs 的 legacy 解密路径——保留（tt/xhs 仍依赖）。
- `code2session`、订阅消息、小程序码（008 的地盘）。
- web 前端（`web/`）——此 mutation 仅小程序消费。
- 隐私指引文档的措辞更新（手机号获取方式变化不影响「收集什么」的披露语义；
  若 compliance 复审要求提及新 API，另开 docs 任务）。

## Git workflow

- Branch: `advisor/009-phonecode-contract`
- Commit style 先例：`feat(accounts): signInWithPlatform 接入 phoneCode——微信侧 SDK getuserphonenumber 直取 (#NNN)`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: 后端 action 参数与取号逻辑

1. `miniprogram.ex` 的 `build_sign_in_action/2`：三个手机号参数重排为——
   新增 `phone_code`（`allow_nil?: true, sensitive?: true`，description
   「getPhoneNumber 动态 code（新契约；wechat 平台）」）；`encrypted_data` 与 `iv` 的
   `allow_nil?: false` 改为 `true`（契约改为「phone_code 或 encrypted_data+iv 二选一，
   由 Preparation 校验组合」）。
2. `sign_in_preparation.ex` 的 `do_sign_in/2` 手机号分支：

```elixir
    phone_code = Query.get_argument(query, :phone_code)
    ...
    with {:ok, session} <- Client.code2session(platform, code),
         {:ok, phone} <- fetch_phone(platform, session, phone_code, encrypted_data, iv),
```

```elixir
  # 手机号获取优先级：wechat + phone_code → 新 API（不触碰 session_key）；
  # 否则 legacy session_key 解密。组合不完整（phone_code 缺且 encrypted_data/iv
  # 不齐；或非 wechat 平台只给 phone_code）→ 统一认证失败（防枚举语义不变）。
  defp fetch_phone(:wechat, %{openid: openid}, phone_code, _encrypted_data, _iv)
       when is_binary(phone_code) and phone_code != "" do
    Client.fetch_phone_by_code(:wechat, openid, phone_code)
  end

  defp fetch_phone(platform, session, nil, encrypted_data, iv)
       when platform in [:wechat, :tt, :xhs] do
    Client.decrypt_phone(platform, session, encrypted_data, iv)
  end

  defp fetch_phone(_platform, _session, _phone_code, _encrypted_data, _iv), do: {:error, :phone_payload_incomplete}
```

   （`:phone_payload_incomplete` 走既有 `authentication_failed(query, reason)` 通道——
   先读 `:193-207` 的净化语义，确认 reason 原子可直接透传。）
3. `client.ex` 新增公开函数（facade 三平台形状；复用文件内既有 `normalize_phone/2`）：

```elixir
  @doc """
  phoneCode → 手机号（getPhoneNumber 新契约，仅 wechat）。

  SDK：POST /wxa/business/getuserphonenumber；成功 body phone_info 含
  purePhoneNumber/phoneNumber + countryCode——归一化为与 decrypt_phone 相同的
  `+区号号码` 形（phone-keyed find-or-create 的确定性前提，见 decrypt_phone 注释）。
  tt/xhs 无等价 API → {:error, :phone_code_unsupported}。
  """
  @spec fetch_phone_by_code(platform, String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def fetch_phone_by_code(:wechat, openid, phone_code)
      when is_binary(openid) and is_binary(phone_code) do
    with {:ok, client} <- WechatClient.fetch(),
         {:ok, %Tesla.Env{status: 200, body: %{"errcode" => 0, "phone_info" => info}}} <-
           WeChat.MiniProgram.UserInfo.get_phone_number(client, openid, phone_code),
         local when is_binary(local) <- info["purePhoneNumber"] || info["phoneNumber"],
         phone when is_binary(phone) <- normalize_phone(local, info["countryCode"]) do
      {:ok, phone}
    else
      _ -> {:error, :phone_fetch_failed}
    end
  end

  def fetch_phone_by_code(_platform, _openid, _phone_code),
    do: {:error, :phone_code_unsupported}
```

   （`normalize_phone` 返回 nil 时落入 `:phone_fetch_failed`——fail-closed 与
   `extract_phone` 的 countryCode 缺失语义一致。）

**Verify**: `cd backend && mix compile --warnings-as-errors` → exit 0

### Step 2: GraphQL 契约

`graphql_schema.ex` 的 `sign_in_with_platform` field：`encrypted_data`/`iv` 改
`arg(:encrypted_data, :string)`（可空），新增 `arg(:phone_code, :string)`；resolver
参数模式与 `for_read` params map 同步加 `phone_code`（透传，nil 安全）。
`user.ex:24` moduledoc 的 mutation 形状行更新为
`signInWithPlatform(platform:, code:, phoneCode:, encryptedData:, iv:)`（后两者可空）。

**Verify**: `mix compile --warnings-as-errors` → exit 0；
`mix test` → 既有登录测试（legacy 路径）全绿。

### Step 3: 前端契约

1. `operations.ts` 的 `SignInWithPlatform` 文档：变量块改为

```graphql
  mutation SignInWithPlatform(
    $platform: String!
    $code: String!
    $phoneCode: String
    $encryptedData: String
    $iv: String
  ) { signInWithPlatform(
      platform: $platform
      code: $code
      phoneCode: $phoneCode
      encryptedData: $encryptedData
      iv: $iv
    ) { ... } }
```

   （保持该文件现有字段选择集不动，只改变量声明与传参。）
2. `platform/index.ts` 收尾段改为：weapp 且 `phonePayload.code` 存在 → 新契约优先
   （不要求 encryptedData/iv）；否则维持 legacy 校验：

```ts
  const login = await Taro.login()
  const isWeapp = process.env.TARO_ENV === 'weapp'
  if (isWeapp && phonePayload.code) {
    if (!login.code) throw new Error('登录凭证获取失败，请重试')
    return { ...phonePayload, loginCode: login.code }
  }
  const encryptedData = phonePayload.encryptedData
  const iv = phonePayload.iv
  if (!login.code || !encryptedData || !iv) {
    throw new Error('手机号授权数据不完整，请重新授权后重试')
  }
  return { ...phonePayload, loginCode: login.code, encryptedData, iv }
```

3. `models.ts`：`signIn` 入参类型加 `phoneCode?: string`、`encryptedData?: string`、
   `iv?: string`（原必填改为可选，code 必填不变）；`real.ts` 的 `signIn` 把
   `phonePayload.code` 作为 `phoneCode` 传入 mutation variables（有值才带键，
   与现有可选字段写法一致）。
4. `pnpm codegen` 重新生成 `src/api/generated/` 并提交。

**Verify**: `cd miniprogram && pnpm codegen && pnpm typecheck` → exit 0

### Step 4: 测试

后端（登录策略测试文件——用 `grep -rn "sign_in_with_miniprogram" backend/test/` 定位；
桩 helper 在 `test/support/miniprogram_fixtures.ex`）：
- wechat + phoneCode 用例：code2session 桩照旧（Req.Test），getuserphonenumber 用
  Tesla.Mock（plan 008 用法）：成功返回
  `%{"errcode" => 0, "phone_info" => %{"purePhoneNumber" => "13800001234", "countryCode" => "86"}}`
  → 断言登录成功且 phone 锚定 `+8613800001234`；
- errcode 非零 → 认证失败（防枚举响应形状与既有失败用例一致）；
- phone_code 缺 + encrypted_data/iv 缺 → 认证失败；
- tt + 只给 phone_code → 认证失败（unsupported 组合 fail-closed）；
- 既有 legacy 用例（三平台 encryptedData/iv）必须原样全绿（回归）。

前端（`tests/real-auth.test.ts`）：
- mockTransport 兼容：SignInWithPlatform mock 分支补 `phoneCode` 变量透传（不校验形状）；
- 新用例：`signIn` 传入含 `code` 的 phonePayload（weapp 分支）→ 断言 mutation variables
  含 `phoneCode` 且不含 `encryptedData`。

**Verify**: `cd backend && mix test` 全绿；`cd miniprogram && pnpm test:unit` 全绿。

### Step 5: 格式与全量

**Verify**: `mix format`（backend 改动文件）+ `mix format --check-formatted` → exit 0；
两端全量测试绿。

## Test plan

- 用例清单见 Step 4（新 API 成功/失败、组合校验 fail-closed、legacy 回归、前端变量形状）。
- 结构先例：后端 `miniprogram_fixtures.ex` + plan 008 的 Tesla.Mock；前端 `real-auth.test.ts`。

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd backend && mix compile --warnings-as-errors` exit 0
- [ ] `cd backend && mix test` exit 0（含 ≥4 个新登录用例）
- [ ] `cd miniprogram && pnpm typecheck && pnpm test:unit` exit 0
- [ ] `grep -n "phone_code" backend/lib/cgc_2046/accounts/strategies/miniprogram.ex` 命中
      argument 构建块
- [ ] `grep -n "phoneCode" miniprogram/src/api/operations.ts` 命中变量声明与传参
- [ ] `git status` 无 in-scope 外改动；`advisor-plans/README.md` 状态行已更新

## STOP conditions

Stop and report back (do not improvise) if:

- plan 008 的 `WechatClient` 未合入或模块名/签名不同（fetch/0 语义不一致时报告）。
- `WeChat.MiniProgram.UserInfo.get_phone_number/3` 实际签名/路径与 Current state 不符
  （读 deps/wechat/lib/wechat/mini_program/user_info.ex:130 一带确认）。
- `authentication_failed/2`（sign_in_preparation.ex:193-207）不接受裸 reason 原子
  （需要先看它的净化逻辑再定错误形状）。
- GraphQL 层对可空 mutation 参数（`arg :encrypted_data, :string`）与 codegen 产物
  出现类型冲突无法一次收敛（报告 typecheck 原始错误）。
- mockTransport 的 operation 匹配因文档变更失效（E2E mock 路径报 unknown operation）。

## Maintenance notes

- 真机验收项：REAL_DEVICE_CHECKLIST N1 的「phoneCode 契约」在完成后勾掉；
  验收时确认开发者工具基础库版本 ≥ 新契约下限。
- legacy encryptedData/iv 路径的退役：等 tt/xhs 官方提供等价 code API 后整体切换，
  届时删 `decrypt_phone` 与 session_key 持有点（那是红线弱化的真正收益兑现点）。
- `phone_code` 与 `code`（loginCode）是两个不同凭证，复审时别混——前者换手机号，
  后者换会话。
- 复审重点：`fetch_phone` 的组合校验是否所有非法组合都 fail-closed（防枚举语义）。
