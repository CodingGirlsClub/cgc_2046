# Plan 008: Miniprogram.Client 微信分支接入 wechat_sdk（token 缓存/重试/自愈）+ 修正通知与小程序码落页 + errcode 保真

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 048c9f8..HEAD -- backend/lib/cgc_2046/miniprogram/ backend/lib/cgc_2046/application.ex backend/config/test.exs backend/test/cgc_2046/miniprogram_code_test.exs backend/test/cgc_2046/notification_service_test.exs`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none（与 006/007 并行安全；009 依赖本计划）
- **Category**: tech-debt / bug
- **Planned at**: commit `048c9f8`, 2026-08-18

## Why this matters

三个叠加问题，都在 `Cgc2046.Miniprogram.Client`：

1. **token 现取现用**：wechat 分支每次 `send_notification`/`generate_code` 都重新 GET
   `/cgi-bin/token`（无缓存、无过期判断），且 Req 配置 `retry: false`——微信网关瞬时
   抖动直接失败，token 失效（40001/42001）无自愈。已装的 wechat_sdk 对此有整套现成
   基础设施：ETS 缓存 + GenServer 定时刷新（过期前 30min，失败 60s 重试）+ TokenChecker
   失效探测 + Tesla Retry×3。
2. **落页硬编码到不存在的页面**：订阅消息三端都跳 `pages/mine/index`、小程序码三端都
   跳 `pages/invite/index`——`miniprogram/src/app.config.ts` 里这两个页面**都不存在**
   （实际存在的是 `pages/profile/index` 与 `pages/join/index`）。真实环境下：
   用户点订阅消息 → 「页面不存在」；扫邀请码 → 同样断裂。
3. **errcode 全丢**：微信 200 + JSON 错误体（43101 用户拒收 / 41030 页面无效 / 45009
   限流）被压平成 `{:error, {:platform_http_status, 200}}`——HTTP 200 被当错误码返回，
   真实原因不可诊断。

本计划把 wechat 分支的 token 依赖面迁到 SDK client（保留三平台 facade API 不变——
tt/xhs 仍走 Req，SDK 只覆盖 wechat），落页改为真实存在的页面，errcode 提取进错误元组。
这也是 plan 009（phoneCode 新契约）的前置：`UserInfo.get_phone_number/3` 需要 SDK client。

## Current state

- `backend/lib/cgc_2046/miniprogram/client.ex` — 三平台 facade（`@platforms [:wechat, :tt, :xhs]`），
  公开面 `code2session/2`、`generate_code/2`、`send_notification/4`、`decrypt_phone/4`、
  `platforms/0`。调用方（勿改契约）：
  - `sign_in_preparation.ex:50` → `code2session`（登录，**不走 access_token**）
  - `notification_service.ex:20` → `send_notification`
  - `miniprogram_code.ex:58` → `generate_code`
- 关键摘录（本计划的改动点）：

```elixir
  # client.ex:84-96 —— 订阅消息 wechat 分支（page 硬编码，落页不存在）
  defp request_notification(:wechat, token, openid, template_id, data) do
    "https://api.weixin.qq.com"
    |> req()
    |> Req.post(
      url: "/cgi-bin/message/subscribe/send",
      params: [access_token: token],
      json: %{touser: openid, template_id: template_id, page: "pages/mine/index", data: data}
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"errcode" => 0}}} -> :ok
      response -> parse_platform_failure(response)
    end
  end
```

```elixir
  # client.ex:132-140 —— token 现取现用，无缓存
  defp fetch_api_access_token(:wechat, config) do
    "https://api.weixin.qq.com"
    |> req()
    |> Req.get(
      url: "/cgi-bin/token",
      params: [grant_type: "client_credential", appid: config.appid, secret: config.secret]
    )
    |> parse_access_token(:wechat)
  end
```

```elixir
  # client.ex:180-189 —— 小程序码 wechat 分支（page 硬编码，落页不存在）
  defp request_code(:wechat, _config, token, scene) do
    "https://api.weixin.qq.com"
    |> req()
    |> Req.post(
      url: "/wxa/getwxacodeunlimit",
      params: [access_token: token],
      json: %{scene: scene, page: "pages/invite/index", check_path: false}
    )
    |> parse_binary_image()
  end
```

```elixir
  # client.ex:235-238 + 256-260 —— errcode 丢失点：
  # JSON 错误体（Req 自动 decode 为 map）不命中 is_binary(body) 子句，
  # 落入 parse_platform_failure → {:error, {:platform_http_status, 200}}
  defp parse_binary_image({:ok, %Req.Response{status: 200, body: body}}) when is_binary(body),
    do: {:ok, body}

  defp parse_binary_image(response), do: parse_platform_failure(response)

  defp parse_platform_failure({:ok, %Req.Response{status: status}}),
    do: {:error, {:platform_http_status, status}}
```

- tt/xhs 分支的 page 同样硬编码（client.ex:107 `pages/mine/index`、:124 同；
  :200/:223 `pages/invite/index`）——一并修正。
- 前端页面事实（落页依据）：`miniprogram/src/app.config.ts` 中
  `pages/profile/index` 仅在 fullPages（weapp）；`pages/my-enrollments/index` 与
  `pages/join/index` 在 cutPages 与 fullPages 都存在。scene 消费链路在
  `miniprogram/src/app.tsx:7-12`（useLaunch → pendingScene → navigateTo join）。
- SDK 侧事实（deps/wechat，勿改）：
  - 动态 client（运行时配置，编译期宏不可用）：`WeChat.build_client(module,
    app_type: :mini_program, appid: ..., appsecret: ...)`（wechat.ex:185-206，
    `Module.create` + `use WeChat.Builder.OfficialAccount`）；
    `WeChat.start_client(client)`（wechat.ex:209-230）= setup_client +
    TokenChecker.add_to_check_clients + add_to_refresher。**注意：start_client 会把
    client 注册进 SDK 全局 Refresher/TokenChecker（跨测试泄漏）——测试禁止调用真实
    start_client**（见 Step 1 测试策略）。
  - client 生成 `get_access_token/0` = `WeChat.Storage.Cache.get_cache(appid, :access_token)`
    （ETS 读；测试可直接 `Cache.put_cache/2` 种 token，零外呼）。
  - `WeChat.MiniProgram.SubscribeMessage.send(client, openid, template_id, data, options)`
    （official_account/subscribe_message.ex，send_mini → POST /cgi-bin/message/subscribe/send，
    options 支持 page）。返回 `{:ok, %Tesla.Env{status: 200, body: %{"errcode" => 0, ...}}}`。
  - `WeChat.MiniProgram.Code.create_code_unlimited(client, scene, options)`
    （code.ex:88-94，POST /wxa/getwxacodeunlimit，options 支持 page/check_path）。
    成功返回 body 为图片二进制；错误 body 为 JSON（Tesla.Middleware.JSON 解码为 map）。
  - **test 环境请求器**：`requester/official_account.ex:33-37` 有
    `if Mix.env() == :test` 分支 → Tesla.Mock。CGC `mix test` 时 SDK 走 Tesla.Mock，
    wechat 分支测试用 `Tesla.Mock.mock/1`（fun 对 URL/body 断言），tt/xhs 分支保持
    `Req.Test` 桩不变。
- 测试现状（要改的两个桩文件）：
  - `backend/test/cgc_2046/notification_service_test.exs:14-37`：
    `Req.Test.stub(Cgc2046.MiniprogramClientStub, fn conn -> ... end)` 按
    `{method, host, path}` 三元组分发；wechat 的 `/cgi-bin/token` 与
    `/cgi-bin/message/subscribe/send` 分支在本计划后改为 Tesla.Mock。
  - `backend/test/cgc_2046/miniprogram_code_test.exs`：同样 stub `/cgi-bin/token` +
    `/wxa/getwxacodeunlimit`；现有断言覆盖 scene 透传/缓存/配额，**从未断言 page 参数**
    ——本计划补上。
- 配置现状：`backend/config/config.exs:54-61` dummy `:miniprogram_platforms`（dev/test）；
  `runtime.exs:128-145` prod `fetch_env!`。`config :wechat` 目前零配置（本计划新增）。
- 仓库运行时 client 先例（本计划照抄的 pattern）：
  `wechat_pay.ex:148-190`——`build_client` + `:persistent_term` 按配置指纹缓存 +
  `fetch_env` 语义注释。**先读这段再动手。**

## Commands you will need

| Purpose | Command (cwd = `backend/`) | Expected on success |
|---------|---------------------------|---------------------|
| Compile | `mix compile --warnings-as-errors` | exit 0 |
| Format | `mix format <改动的文件>` 后 `mix format --check-formatted` | exit 0 |
| 目标测试 | `mix test test/cgc_2046/notification_service_test.exs test/cgc_2046/miniprogram_code_test.exs` | 全绿 |
| 全量 | `mix test` | 全绿 |

## Scope

**In scope**:
- `backend/lib/cgc_2046/miniprogram/client.ex`
- `backend/lib/cgc_2046/miniprogram/wechat_client.ex`（新建，SDK client 宿主）
- `backend/config/config.exs`（仅加 `config :wechat, ...` 相关键，若需要）
- `backend/config/test.exs`（仅加 wechat_client 测试开关）
- `backend/test/cgc_2046/notification_service_test.exs`
- `backend/test/cgc_2046/miniprogram_code_test.exs`

**Out of scope**:
- `code2session`、`decrypt_phone`、tt/xhs 的全部 HTTP 路径——保持 Req 直调不变
  （code2session 不依赖 access_token；tt/xhs SDK 不覆盖）。
- `miniprogram_code.ex`、`notification_service.ex`、`notification_consent.ex`——facade
  公开 API 与语义（`:ok` / `{:error, reason}` / consent 回补）不变，调用方零改动。
- GraphQL schema / 前端任何文件（落页只改后端下发的 page 字符串）。
- `deps/wechat/**`。
- plan 009 的 phoneCode——别顺手做。

## Git workflow

- Branch: `advisor/008-miniprogram-wechat-sdk`
- Commit style 先例：`refactor(miniprogram): wechat 分支接 wechat_sdk client——token 缓存+落页修正+errcode 保真 (#NNN)`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: wechat_client 宿主模块

新建 `backend/lib/cgc_2046/miniprogram/wechat_client.ex`（pattern 照抄
`wechat_pay.ex:148-190` 的 fetch_client/build_cached_client/persistent_term 指纹缓存）：

```elixir
defmodule Cgc2046.Miniprogram.WechatClient do
  @moduledoc """
  微信小程序 SDK client 宿主（运行时配置 → WeChat.build_client 动态模块）。

  - 首次使用时按 :miniprogram_platforms 的 wechat 配置构建 + 启动
    （WeChat.start_client：注册 Refresher 定时刷新 + TokenChecker 失效自愈；
    token 存 SDK ETS，WeChat.Storage.Cache）。
  - 未配置（config 缺 wechat 键）→ {:error, :wechat_not_configured}。
  - 测试环境不启动全局 Refresher（防跨用例泄漏）；token 由测试直接种
    WeChat.Storage.Cache（见 wechat_token_seed 注入约定）。
  """

  @start_key {__MODULE__, :started_fingerprint}

  @spec fetch() :: {:ok, module()} | {:error, :wechat_not_configured}
  def fetch do
    case wechat_config() do
      %{appid: appid, secret: secret} when is_binary(appid) and is_binary(secret) ->
        fingerprint = :erlang.phash2({appid, secret})

        case :persistent_term.get({__MODULE__, fingerprint}, nil) do
          nil ->
            client_module = Module.concat(__MODULE__, "Client#{fingerprint}")

            with {:module, module} <-
                   WeChat.build_client(client_module,
                     app_type: :mini_program,
                     appid: appid,
                     appsecret: secret,
                     requester: WeChat.Requester.OfficialAccount
                   ) do
              maybe_start(module, fingerprint)
              :persistent_term.put({__MODULE__, fingerprint}, module)
              {:ok, module}
            else
              {:error, reason} -> raise "wechat mini program client build failed: #{inspect(reason)}"
            end

          module ->
            {:ok, module}
        end

      _ ->
        {:error, :wechat_not_configured}
    end
  end

  # start_client 会把 client 注册进 SDK 全局 Refresher/TokenChecker；
  # 仅非 test 环境执行（test 用 Cache 种 token，零全局副作用）。
  defp maybe_start(module, fingerprint) do
    if Application.get_env(:cgc_2046, :wechat_client_autostart, true) and
         :persistent_term.get(@start_key, nil) != fingerprint do
      :ok = WeChat.start_client(module)
      :persistent_term.put(@start_key, fingerprint)
    end
  end

  defp wechat_config do
    :cgc_2046
    |> Application.get_env(:miniprogram_platforms, %{})
    |> Map.get(:wechat, %{})
    |> Map.take([:appid, :secret])
    |> case do
      %{appid: appid, secret: secret} -> %{appid: appid, secret: secret}
      _ -> %{}
    end
  end
end
```

`backend/config/test.exs` 追加一行：`config :cgc_2046, :wechat_client_autostart, false`。

（注意 `WeChat.build_client` 的返回是 `{:module, module, _, _}` with 匹配 `{:module, module}`；
若实际形状不同——对照 deps/wechat/lib/wechat.ex:185-206——按实际改。）

**Verify**: `mix compile --warnings-as-errors` → exit 0

### Step 2: 落页修正（三平台 page 常量）

`client.ex` 顶部加模块属性（值以 app.config.ts 现状为准，见 Current state）：

```elixir
  # 落页契约：页面必须存在于 miniprogram/src/app.config.ts。
  # 订阅消息：weapp 有「我的」（profile，本机通知中心）；裁剪端无 profile，
  # 落「我的报名」（三端都注册的 tab 页）。小程序码：join 三端都注册且消费 scene
  # （miniprogram/src/app.tsx useLaunch → pendingScene → join）。
  @notification_page %{
    wechat: "pages/profile/index",
    tt: "pages/my-enrollments/index",
    xhs: "pages/my-enrollments/index"
  }
  @code_page "pages/join/index"
```

三个 `request_notification` 分支与三个 `request_code` 分支的 `page:` 改为读这些常量
（tt 的 `path: "pages/invite/index?scene=#{scene}"` → `"#{@code_page}?scene=#{scene}"`）。

**Verify**: `mix compile --warnings-as-errors` → exit 0；
`grep -n "pages/mine\|pages/invite" lib/cgc_2046/miniprogram/client.ex` → **零命中**。

### Step 3: wechat 分支迁 SDK + errcode 保真

`client.ex` 改造（公开 API 不变）：

1. `send_notification(:wechat, ...)` 分支整体替换为 SDK 调用：

```elixir
  defp request_notification(:wechat, openid, template_id, data) do
    with {:ok, client} <- WechatClient.fetch() do
      client
      |> WeChat.MiniProgram.SubscribeMessage.send(
        openid,
        template_id,
        data,
        %{page: @notification_page.wechat}
      )
      |> parse_wechat_envelope()
    end
  end

  # SDK 信封：成功 {:ok, %Tesla.Env{status: 200, body: %{"errcode" => 0}}}；
  # 业务失败 200 + %{"errcode" => code, "errmsg" => msg}——errcode 保真出栈。
  defp parse_wechat_envelope({:ok, %Tesla.Env{status: 200, body: %{"errcode" => 0}}}), do: :ok

  defp parse_wechat_envelope({:ok, %Tesla.Env{status: 200, body: %{"errcode" => code, "errmsg" => msg}})
       when is_integer(code),
       do: {:error, {:platform_rejected, code, msg}}

  defp parse_wechat_envelope({:ok, %Tesla.Env{status: status}}),
    do: {:error, {:platform_http_status, status}}

  defp parse_wechat_envelope({:error, _}), do: {:error, :platform_unreachable}
  defp parse_wechat_envelope(_), do: {:error, :platform_bad_response}
```

   `send_notification/4` 公开函数的 wechat 分支不再经过 `fetch_api_access_token`
   （token 由 SDK client 内部管理）。
2. `request_code(:wechat, scene)` 同样替换：

```elixir
  defp request_code(:wechat, scene) do
    with {:ok, client} <- WechatClient.fetch() do
      client
      |> WeChat.MiniProgram.Code.create_code_unlimited(scene, %{
        page: @code_page,
        check_path: false
      })
      |> parse_wechat_image()
    end
  end

  # 成功 body 为图片二进制；错误 body 为 JSON map（Tesla 中间件已解码）。
  defp parse_wechat_image({:ok, %Tesla.Env{status: 200, body: body}}) when is_binary(body),
    do: {:ok, body}

  defp parse_wechat_image({:ok, %Tesla.Env{status: 200, body: %{"errcode" => code, "errmsg" => msg}}})
       when is_integer(code),
       do: {:error, {:platform_rejected, code, msg}}

  defp parse_wechat_image(response), do: parse_wechat_envelope(response)
```

3. **errcode 保真（tt/xhs 保留路径）**：`parse_platform_failure` 之前插入 200+map 信封
   提取，避免 tt/xhs 的 43101 类错误再被压平：

```elixir
  # 200 + JSON 错误体（Req 已解码为 map）——先提 errcode/err_no/code，再谈 HTTP 状态。
  defp parse_platform_failure({:ok, %Req.Response{status: 200, body: %{"errcode" => code, "errmsg" => msg}})
       when is_integer(code) and code != 0,
       do: {:error, {:platform_rejected, code, msg}}

  defp parse_platform_failure({:ok, %Req.Response{status: 200, body: %{"err_no" => code, "err_msg" => msg}}})
       when is_integer(code) and code != 0,
       do: {:error, {:platform_rejected, code, msg || ""}}

  defp parse_platform_failure({:ok, %Req.Response{status: 200, body: %{"code" => code, "msg" => msg}}})
       when is_integer(code) and code != 0,
       do: {:error, {:platform_rejected, code, msg || ""}}
```

4. `fetch_api_access_token(:wechat, _)`、原 `request_notification(:wechat, token, ...)`、
   原 `request_code(:wechat, _config, token, scene)` 删除（干净 cutover，仓库规则不留死路径）。
   `fetch_api_access_token` 剩 tt/xhs 两个子句。

**Verify**: `mix compile --warnings-as-errors` → exit 0（若有 unused function 警告，
按警告删净——不许留 `@compile :ignore_unused`）。

### Step 4: 测试改造

1. `notification_service_test.exs`：wechat 用例改为——setup 里
   `WeChat.Storage.Cache.put_cache` 不适用（appid 未知）？**不需要种 token**：
   Tesla.Mock 拦截在请求层，`get_access_token` 读 ETS 得 nil 只影响 query 参数；
   SDK send 的 access_token 来自 `client.get_access_token()`（query 里值为 nil，
   mock 不校验它）。改为：

```elixir
    Tesla.Mock.mock(fn
      %{method: :post, url: "https://api.weixin.qq.com/cgi-bin/message/subscribe/send" <> _} ->
        Tesla.Mock.json(%{"errcode" => 0})
    end)
```

   断言：`:ok`；并断言请求体 page == `"pages/profile/index"`（Tesla.Mock 的
   `fn env -> ... end` 里可对 `env.body` 做模式匹配/断言——在 mock fun 内
   `assert Jason.decode!(env.body)["page"] == "pages/profile/index"` 后再返回）。
   补一个 errcode 用例：mock 返回 `%{"errcode" => 43101, "errmsg" => "user refuse"}` →
   断言 consent 回补（沿用现有 refund 断言模式）且错误为
   `{:platform_rejected, 43101, "user refuse"}`。
   tt/xhs 用例的 Req.Test 桩原样保留（page 断言补上：tt/xhs 分别为
   `pages/my-enrollments/index`）。
2. `miniprogram_code_test.exs`：wechat 用例同法改 Tesla.Mock
   （`/wxa/getwxacodeunlimit`，返回 `Tesla.Mock.response(200, <<1, 2, 3>>, "image/jpeg")`；
   body 直接给二进制）；断言请求体 `page == "pages/join/index"` 且 `check_path == false`、
   scene 透传。补 41030 反例：
   `Tesla.Mock.json(%{"errcode" => 41030, "errmsg" => "invalid page"})` →
   `{:error, {:platform_rejected, 41030, _}}`。tt/xhs 用例保留 Req.Test。
   缓存/配额断言（同 invitation 二次取缓存、日配额）不改语义，仍需全绿。
3. 全量跑（确认 code2session 登录测试不受影响——它们全程 Req.Test，未动）。

**Verify**: `mix test test/cgc_2046/notification_service_test.exs test/cgc_2046/miniprogram_code_test.exs` → 全绿

### Step 5: 全量回归 + 格式

**Verify**:
- `mix format lib/cgc_2046/miniprogram/ config/test.exs test/cgc_2046/notification_service_test.exs test/cgc_2046/miniprogram_code_test.exs`
  然后 `mix format --check-formatted` → exit 0
- `mix test` → 全绿

## Test plan

- 改造文件见 Step 4；新增断言清单：落页（wechat profile / tt my-enrollments /
  xhs my-enrollments / 码 join）、errcode 保真（43101 通知 / 41030 码）、consent 回补、
  scene/check_path 透传、缓存与配额回归。
- 结构先例：两个既有测试文件的 `Req.Test.stub` 三元组分发 + describe 组织。
- Tesla.Mock 先例：无（本仓库首次）——mock fun 内断言请求体后返回响应，见 Step 4 示例。

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd backend && mix compile --warnings-as-errors` exit 0
- [ ] `cd backend && mix test` exit 0
- [ ] `grep -rn "pages/mine\|pages/invite" backend/lib/` 零命中
- [ ] `grep -n "fetch_api_access_token" backend/lib/cgc_2046/miniprogram/client.ex`
      仅剩 tt/xhs 子句（无 :wechat 子句）
- [ ] `grep -n "WeChat.MiniProgram" backend/lib/cgc_2046/miniprogram/client.ex` 命中
      SubscribeMessage 与 Code 两处
- [ ] 测试含 `{:platform_rejected, 43101` 与 `{:platform_rejected, 41030` 断言
- [ ] `git status` 无 in-scope 外改动；`advisor-plans/README.md` 状态行已更新

## STOP conditions

Stop and report back (do not improvise) if:

- `WeChat.build_client/2` 实际返回形状/选项与 Current state 摘录不符（对照
  deps/wechat/lib/wechat.ex:185-206 后报告差异）。
- `WeChat.MiniProgram.SubscribeMessage.send/5` 的 options 不接受 `page` 键（读
  deps/wechat/lib/wechat/official_account/subscribe_message.ex 的 send_mini 实现确认；
  不接受则改用其文档声明的等价参数名，仍不行 = STOP）。
- `Tesla.Mock.mock/1` 在 ExUnit 用例中出现跨用例污染（第二个用例拿到第一个的 fun）——
  报告现象，不要改用全局桩。
- SDK 在 test 环境编译后 `Requester.OfficialAccount` 仍走 Finch（`Mix.env() == :test`
  分支未生效）：测试将真实外呼——立即 STOP 并报告（不允许带外呼的测试）。
- `WeChat.start_client/2` 在 dev 环境（dummy appid）导致 Refresher 崩溃循环或刷屏
  以外的异常（正常预期：每 60s 一次 warning 日志，无害）。

## Maintenance notes

- 落页契约现在锚定在 `@notification_page`/`@code_page` 两处常量——前端 app.config.ts
  改页面路径时必须同步这里（复审 PR 时先 diff app.config.ts）。
- tt/xhs 订阅消息落 tab 页（my-enrollments）在真机上的点击行为属 Phase 4 联调项
  （DOUYIN_REDNOTE_CHECKLIST），CI 只能断言下发的 page 值。
- dev 环境未配真实 appid 时 Refresher 每 60s 打 warning——已知噪音，别当 bug 修。
- plan 009（phoneCode）将复用 `WechatClient.fetch()`——本模块是它的唯一 SDK 入口。
- 若未来 tt/xhs 也想接 SDK 化 token 管理，`WechatClient` 的 pattern 可复制，但 SDK
  不覆盖这两个平台，别抽象共享层。
