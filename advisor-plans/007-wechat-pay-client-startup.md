# Plan 007: 让微信支付真实链路可用——启动 SDK client（证书加载 + Finch 池）、补 webhook_base_url 配置门、建立 adapter 直接测试

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 048c9f8..HEAD -- backend/lib/cgc_2046/payments/providers/wechat_pay.ex backend/lib/cgc_2046/application.ex backend/test/cgc_2046/payments/ backend/config/test.exs`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: bug / tests
- **Planned at**: commit `048c9f8`, 2026-08-18

## Why this matters

WechatPay adapter 只调用了 `WeChat.Pay.build_client/2`——但 SDK 源码里 `build_client`
仅仅是 `Module.create`（deps/wechat/lib/wechat/pay/pay.ex:144-161），**不启动任何进程**。
平台证书加载（`make_sure_certs`，只在 `use WeChat.Pay` 生成的 Supervisor `init` 里被
`Refresher.Pay` 调用）和 per-client 命名 Finch 池（`:"#{client}.Finch"`，由
`get_requester_specs` child spec 启动）都依赖 `start_link` 被调用——而
`Cgc2046.Application` 的 children 里没有任何支付 client。后果（真实密钥环境）：

1. **回调验签恒失败**：`Certificates.get_cert(client, serial)` 读 `:persistent_term`，
   证书从未被 put 进去，恒返回 nil → `verify_webhook` 恒 `:error`。
2. **首次真实外呼即崩**：`Requester.Pay` 用 `{Tesla.Adapter.Finch, name: :"#{client}.Finch"}`，
   池不存在 → tesla 抛 `noproc` exit（adapter 的 rescue 在 fetch_client，兜不住这里）。
3. SDK 的平台证书 12h 轮换能力被整体绕开。

另一处：`configured?/0` 五键不含 `webhook_base_url`（prod runtime.exs 该键无默认值），
配齐商户密钥但漏配回调域名的环境，首次下单在 `Path.join(nil, _)` 上抛
FunctionClauseError → 500。上线前「真实小额验收」（payment plan 收尾里程碑）当前必然失败。
本计划同时给 adapter 建立直接测试（当前 0 覆盖）。

## Current state

- `backend/lib/cgc_2046/payments/providers/wechat_pay.ex` — 微信支付 APIv3 adapter
  （`@behaviour Cgc2046.Payments.Provider`，五回调）。
  - `:143-146` configured?：

```elixir
  defp configured? do
    config()[:mch_id] && config()[:appid] && config()[:api_v3_key] &&
      config()[:client_serial_no] && config()[:client_private_key]
  end
```

  - `:148-190` fetch_client / build_cached_client（本计划的接入点）：

```elixir
  defp fetch_client do
    if configured?() do
      try do
        {:ok, build_cached_client()}
      rescue
        _ -> {:error, :provider_not_configured}
      end
    else
      {:error, :provider_not_configured}
    end
  end

  defp build_cached_client do
    fingerprint = :erlang.phash2(config())

    case :persistent_term.get({__MODULE__, fingerprint}, nil) do
      nil ->
        client_module = Module.concat(__MODULE__, "Client#{fingerprint}")

        case WeChat.Pay.build_client(client_module,
               mch_id: config()[:mch_id],
               api_secret_key: config()[:api_v3_key],
               client_serial_no: config()[:client_serial_no],
               client_key: {:binary, config()[:client_private_key]}
             ) do
          {:ok, module} ->
            :persistent_term.put({__MODULE__, fingerprint}, module)
            module

          {:error, reason} ->
            raise "wechat pay client build failed: #{inspect(reason)}"
        end

      module ->
        module
    end
  end
```

  - `:192-194` notify_url（B3 崩溃点）：

```elixir
  defp notify_url do
    config()[:webhook_base_url] |> Path.join("/api/payments/webhooks/wechat")
  end
```

  - `:108-121` verify_webhook：取 4 个 wechatpay-* 头 → `Certificates.get_cert(client, serial)`
    → `Crypto.verify(...)` → `Jason.decode` → `decrypt_resource`。

- SDK 侧事实（deps/wechat，勿改）：
  - `builder/pay.ex`：`use WeChat.Pay` 生成 `use Supervisor` 模块；`start_link(opts)` →
    `init` 启动 `{WeChat.Refresher.Pay, %{client: __MODULE__}} | WeChat.Pay.get_requester_specs(__MODULE__, opts)`；
    `get_requester_specs` 返回 `[Finch.child_spec(name: finch_name(client), ...) |> Map.put(:id, Finch)]`
    （v2_ssl 未配置时仅 v3 一个）。
  - `refresher/pay.ex:28` `make_sure_certs(client)`：storage.restore 命中 → `put_certs`；
    未命中（`:error`）→ `WeChat.Pay.init_certs(client)`（**发起 HTTP 下载平台证书**）。
  - `certificates.ex:96-99`：`get_cert(client, serial_no)` =
    `:persistent_term.get({:wechat, {client, serial_no}}, nil)`；
    `put_cert(client, serial_no, cert)` 是**公开函数**（测试可用它直接种证书）。
  - `pay.ex:167-183`：`WeChat.Pay.start_client(supervisor, client, options)` /
    `shutdown_client(supervisor, client)`——动态挂到外部 supervisor。
  - **注意**：`Requester.Pay` 没有 test 环境 Tesla.Mock 分支（对比
    `requester/official_account.ex:33-37` 有）；测试不得触发真实 HTTP。

- `backend/lib/cgc_2046/application.ex` — children 列表（`:10-55`，从 Telemetry 到
  Endpoint，one_for_one，name: Cgc2046.Supervisor）。当前无任何 WeChat 相关 child。

- 配置现状：
  - `backend/config/test.exs:61-65` 注入 Fake providers；test 环境**没有** `:wechat_pay`
    配置 → `configured?` 恒 false → 现有测试从不触达真实 adapter（这也是 0 直接测试的原因）。
  - `backend/config/runtime.exs:277-290`：prod `wechat_pay` 经 `System.get_env` 注入
    （允许缺失→`:provider_not_configured`），`webhook_base_url` 无默认值。
  - `backend/config/dev.exs:73-83`：dev `webhook_base_url` 有 `|| "http://localhost:4000"` 兜底。

- 测试先例（本计划复用）：
  - `backend/test/cgc_2046/payments/providers_test.exs:69-100` 的「微信回调验签（RSA-SHA256）
    + AES-GCM 资源解密」describe 块——**先读这个块**：测试内生成 RSA 密钥对、用
    `WeChat.Pay.Crypto.verify/5` 与 `decrypt_aes_256_gcm/4` 构造回环。本计划的
    verify_webhook 集成测试以它为结构模板（密钥对生成 + 签名 + GCM 加密资源体的夹具写法照抄）。
  - `use Cgc2046.DataCase, async: true`；`alias` 风格；中文 @moduledoc 说明测试意图（仓库约定）。

## Commands you will need

| Purpose | Command (cwd = `backend/`) | Expected on success |
|---------|---------------------------|---------------------|
| Compile | `mix compile --warnings-as-errors` | exit 0 |
| Format check | `mix format --check-formatted` | exit 0（改完跑 `mix format <files>`） |
| Tests | `mix test test/cgc_2046/payments/` | 全绿 |
| 全量测试 | `mix test` | 全绿 |

## Scope

**In scope**:
- `backend/lib/cgc_2046/payments/providers/wechat_pay.ex`
- `backend/lib/cgc_2046/application.ex`
- `backend/test/cgc_2046/payments/wechat_pay_test.exs`（新建）
- `backend/test/support/`（如需公共夹具，可加一个模块——命名对齐现有 support 文件）

**Out of scope**:
- `backend/lib/cgc_2046_web/controllers/payment_webhook_controller.ex`——幂等/应答契约已有
  覆盖良好的测试，不动。
- `backend/lib/cgc_2046/payments/providers/alipay.ex`、`fake.ex`——同 behaviour 的兄弟 adapter。
- `backend/config/*.exs`——不新增配置键（webhook_base_url 键已存在，只是没进门禁）。
- `deps/wechat/**`——SDK 源码只读。
- 订阅消息/小程序码/Miniprogram.Client——那是 plan 008 的地盘。

## Git workflow

- Branch: `advisor/007-wechat-pay-client-startup`
- Commit style 先例：`fix(payments): WechatPay client 启动缺失——证书不加载+Finch 池缺失 (#NNN)`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: adapter 特征化测试先行（红）

新建 `backend/test/cgc_2046/payments/wechat_pay_test.exs`，`use Cgc2046.DataCase, async: true`。
夹具：测试内生成 RSA 私钥（`OpenSSL` 或 `:public_key` 生成 2048 位 RSA，参考
providers_test.exs 验签块的做法），构造最小 config map：

```elixir
  # 半配置场景：五键齐 + webhook_base_url 缺失（prod runtime.exs 该键无默认值）
  @base_config [
    appid: "wx-test-appid",
    mch_id: "1900000000",
    api_v3_key: "32bytes-test-api-v3-key-0000000000",
    client_serial_no: "TEST0001",
    client_private_key: test_pem()
  ]
```

（`test_pem/0` 从 providers_test.exs 的密钥对生成代码搬移/复用；若两文件都要用，
提到 `test/support/` 一个公共模块。）

用例（先写「现状下应失败/崩溃」的期望，修复后转绿——**先全部写好再动生产代码**，
这样 Step 2 的效果可被逐条验证）：

1. **provider_not_configured**：清空 `Application.put_env(:cgc_2046, :wechat_pay, [])` →
   `WechatPay.create_payment(order, %{})` 返回 `{:error, :provider_not_configured}`。
2. **B3 半配置**：config = `@base_config`（无 `webhook_base_url`）→
   `create_payment` 返回 `{:error, :provider_not_configured}`（当前实际行为：
   FunctionClauseError 崩溃——此用例修复前必然红）。
3. **verify_webhook 回环**：
   - `Application.put_env(:cgc_2046, :wechat_pay, @base_config ++ [webhook_base_url: "https://cb.example.com"])`
   - 取得 client 模块：本步骤需要拿到 `build_cached_client` 生成的模块名。为可测，
     Step 2 会把 client 获取暴露为 `@doc false def current_client/0`（见 Step 2），
     测试调 `WechatPay.current_client()`。
   - `WeChat.Pay.Certificates.put_cert(client, "TESTSERIAL", platform_cert_pem)`（种平台证书；
     platform_cert_pem = 测试生成的另一张自签证书 PEM——`X509.Certificate.from_pem!` 能解析即可）。
   - 按 providers_test.exs 验签块的写法：构造 raw_body（内含 AEAD_AES_256_GCM resource，
     用 `WeChat.Pay.Crypto` 加密一段 `%{"out_trade_no" => ...}`），用平台证书私钥对
     `timestamp\nnonce\nraw_body` 签名，组装 headers map（小写键，
     `wechatpay-signature/timestamp/nonce/serial`）。
   - 断言 `WechatPay.verify_webhook(raw_body, headers)` 返回 `{:ok, %{...解密后资源体...}}`。
   - 反例断言：篡改 body → `:error`；serial 未种证书 → `:error`。
4. **启动接线断言**（Step 2 之后转绿）：`Process.whereis(:"#{client}.Finch")` 为 pid 且
   `Process.alive?/1`；`DynamicSupervisor.which_children(Cgc2046.Payments.ClientSup)` ≥ 1 child。
5. **每个用例 after 清理**：`Application.delete_env(:cgc_2046, :wechat_pay)`；
   `WeChat.Pay.Certificates.remove_cert(client, "TESTSERIAL")`；
   `:persistent_term.erase({Cgc2046.Payments.Providers.WechatPay, fingerprint})`
   （fingerprint 用 `:erlang.phash2(config)` 同算法重算；写一个私有 helper）。

**Verify**: `mix test test/cgc_2046/payments/wechat_pay_test.exs` →
用例 1 过；用例 2/3/4 红（现状：崩溃/证书 nil/池不存在）。**红的形态必须与
「Why this matters」描述一致**（FunctionClauseError / :error / nil 池）；不一致 = STOP。

### Step 2: 修 B3——webhook_base_url 进 configured? 门

`wechat_pay.ex` 的 `configured?/0` 追加第六键：

```elixir
  defp configured? do
    config()[:mch_id] && config()[:appid] && config()[:api_v3_key] &&
      config()[:client_serial_no] && config()[:client_private_key] &&
      config()[:webhook_base_url]
  end
```

同时新增测试 seam（供 Step 1 用例 3/4 取模块）：

```elixir
  @doc false
  # 测试 seam：当前配置指纹对应的 client 模块（未配置时为 nil）。
  def current_client do
    if configured?(), do: build_cached_client(), else: nil
  end
```

**Verify**: `mix test test/cgc_2046/payments/wechat_pay_test.exs` → 用例 2 转绿
（`{:error, :provider_not_configured}`）。

### Step 3: 修 B1——client 启动接线

1. `backend/lib/cgc_2046/application.ex` children 追加（放 Oban 之前即可，
   one_for_one 顺序无硬约束，但需在 Endpoint 前）：

```elixir
      # WechatPay 动态 client 宿主（证书 Refresher + per-client Finch 池，
      # 首次真实调用时按配置指纹挂载；未配置时恒空）。
      {DynamicSupervisor, name: Cgc2046.Payments.ClientSup},
```

2. `wechat_pay.ex` 的 `build_cached_client`：`{:ok, module}` 分支在
   `:persistent_term.put` 之前启动；命中缓存分支不重复启动。指纹变更时先摘旧 child：

```elixir
        case WeChat.Pay.build_client(client_module, ...) do
          {:ok, module} ->
            start_client_supervisor(module)
            :persistent_term.put({__MODULE__, fingerprint}, module)
            module
          ...
        end
```

```elixir
  # SDK 标准启动路径：use WeChat.Pay 的模块即 Supervisor，start_link 会拉起
  # Refresher.Pay（加载/轮换平台证书进 :persistent_term）与命名 Finch 池
  # （:"#{client}.Finch"，Requester.Pay 外呼依赖）。幂等：重复 start_child 对
  # 已运行同名 Supervisor 会 {:error, :already_started} → 视为成功。
  defp start_client_supervisor(module) do
    case DynamicSupervisor.start_child(Cgc2046.Payments.ClientSup, {module, []}) do
      {:ok, _pid} -> :ok
      {:error, :already_started, _pid} -> :ok
      {:error, :already_present, _pid} -> :ok
    end
  end
```

   旧指纹清理：`build_cached_client` 命中 nil 且 persistent_term 里存在**旧指纹**模块时
   （用 `:persistent_term.get` 遍历 `{__MODULE__, _}` 不可行——persistent_term 无遍历；
   改为在 put 时同时存 `{__MODULE__, :current_fingerprint}`，读到与计算指纹不一致即先
   `WeChat.Pay.shutdown_client(Cgc2046.Payments.ClientSup, old_module)` 再走新建分支）。

3. **测试环境网络红线**：`WeChat.Refresher.Pay.init` 的 `make_sure_certs` 在 storage
   无记录时会 `WeChat.Pay.init_certs(client)` 发起真实 HTTP。测试必须绕开：
   在 wechat_pay_test.exs 的 setup 里给 client 预置证书存储，使 restore 命中。
   SDK 默认 storage 是 `WeChat.Storage.PayFile`（文件存储，路径含 priv）。
   处理方式（按顺序尝试，第一种成功即止）：
   a. `client.storage().store(client.mch_id(), :certs, [%{"serial_no" => "TESTSERIAL", "cert" => platform_cert_pem}])`
      后再触发启动，若 `Refresher.Pay` init 走 restore 分支（不外呼）则采用；
   b. 若 storage 记录形状不匹配（restore 后 put_certs 抛错或仍走 init_certs），
      退到 **fallback**：测试不启动完整 child，改为只启动 Finch 池——
      `DynamicSupervisor.start_child(Cgc2046.Payments.ClientSup, hd(WeChat.Pay.get_requester_specs(client, %{})))`
      + 直接 `Certificates.put_cert` 种证书。同时在 wechat_pay_test 的 moduledoc 里注明
      「Refresher 路径由真实小额验收覆盖，CI 内不启动」。
   两种形态下 Step 1 的用例 4 断言都要成立（Finch alive + supervisor child 存在）。

**Verify**:
- `mix test test/cgc_2046/payments/wechat_pay_test.exs` → 全绿（含用例 3/4）。
- `mix compile --warnings-as-errors` → exit 0。

### Step 4: 全量回归 + 格式

**Verify**:
- `mix format lib/cgc_2046/payments/providers/wechat_pay.ex lib/cgc_2046/application.ex test/cgc_2046/payments/wechat_pay_test.exs`
  然后 `mix format --check-formatted` → exit 0。
- `mix test` → 全绿（Fake 注入路径的行为必须零变化——test.exs 无 wechat_pay 配置，
  `configured?` false，启动接线根本不触发）。

## Test plan

- 新文件 `wechat_pay_test.exs`，用例清单见 Step 1（1 未配置 / 2 半配置门禁 / 3 验签回环
  +篡改反例 +未知 serial 反例 / 4 启动接线）。
- 结构先例：`providers_test.exs:69-100` 验签块（RSA 夹具 + Crypto 回环 + after 清理风格）。
- 既有回归：`mix test` 全量（特别确认 order_test / refund_test / payment_webhook_test 不受影响）。

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd backend && mix compile --warnings-as-errors` exit 0
- [ ] `cd backend && mix test` exit 0
- [ ] `test/cgc_2046/payments/wechat_pay_test.exs` 存在且含 ≥6 断言（含两个反例）
- [ ] `grep -n "webhook_base_url" backend/lib/cgc_2046/payments/providers/wechat_pay.ex`
      在 `configured?` 内命中
- [ ] `grep -n "ClientSup\|start_client_supervisor" backend/lib/cgc_2046/payments/providers/wechat_pay.ex
      backend/lib/cgc_2046/application.ex` 两文件均命中
- [ ] `git status` 无 in-scope 外改动；`advisor-plans/README.md` 状态行已更新

## STOP conditions

Stop and report back (do not improvise) if:

- 现状代码与「Current state」摘录不符（漂移）。
- Step 1 红用例的实际失败形态与预期不同（说明审计结论有误，需重新评估）。
- Step 3 的两种测试形态（a/b）都触发真实外呼（测试日志出现对
  `api.mch.weixin.qq.com` 的连接尝试）：报告并停——不允许带外呼的测试合入。
- `WeChat.Pay.build_client` 在测试 RSA PEM 上直接 `{:error, reason}`
  （说明 SDK 对密钥格式有额外要求——报告 reason）。
- `DynamicSupervisor.start_child(..., {module, []})` 形状不被接受且
  `WeChat.Pay.start_client/3` 也不行（报告两个调用的原始错误）。
- 全量 `mix test` 出现与本计划无关的失败（报告原始输出，不要顺手修）。

## Maintenance notes

- 真实小额人工验收（payment plan 收尾项）执行时：观察日志确认 Refresher.Pay 完成
  平台证书下载（`put_certs` 后 `verify_webhook` 不再依赖手工 put_cert）。
- 复审重点：`build_cached_client` 指纹变更路径是否正确 shutdown 旧 child（防 Finch 池泄漏）；
  `current_client/0` 只允许测试使用（@doc false 已标注）。
- 12h 证书轮换现在由 SDK Refresher 负责——后续若对账 worker 报验签失败，先查
  `ClientSup` 下 Refresher 进程状态。
- 本计划不做 webhook 时间戳新鲜度窗（SDK 自身也不做；幂等索引已缓解重放），如需加固
  另开计划。
