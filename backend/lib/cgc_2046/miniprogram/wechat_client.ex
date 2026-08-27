defmodule Cgc2046.Miniprogram.WechatRequester do
  @moduledoc """
  微信 API Tesla requester（宿主自有，SDK client 的请求层）。

  与 deps/wechat 0.20.0 的 `WeChat.Requester.OfficialAccount` 同构
  （BaseUrl + Retry×3 + JSON（含 text/plain 解码）+ Logger）；SDK 无 adapter
  配置点——其 test 分支靠 dep 编译期 `Mix.env()`，宿主构建实测不生效（仍走
  Finch 真实外呼），故平行实现，adapter 由 `:wechat_tesla_adapter` 编译期注入。
  SDK 升级改 requester 协议（get/post 签名）时需同步本模块。
  """

  # test=Tesla.Mock（config/test.exs 注入）；dev/prod=Finch（与 SDK 默认一致）。
  @adapter Application.compile_env(
             :cgc_2046,
             :wechat_tesla_adapter,
             {Tesla.Adapter.Finch, name: WeChat.Finch}
           )

  @retry_options [
    delay: 500,
    max_retries: 3,
    max_delay: 2_000,
    should_retry: &WeChat.Utils.request_should_retry/1
  ]

  defp middleware do
    [
      {Tesla.Middleware.BaseUrl, "https://api.weixin.qq.com"},
      {Tesla.Middleware.Retry, @retry_options},
      {Tesla.Middleware.JSON, decode_content_types: ["text/plain"]},
      # debug:false——请求/响应 body 不进 debug 日志（getuserphonenumber 的
      # phoneCode/openid 为敏感值，红线同 session_key 不进日志；advisor09 F2）
      {Tesla.Middleware.Logger, debug: false}
    ]
  end

  defp client, do: Tesla.client(middleware(), @adapter)

  def get(url, opts \\ []), do: Tesla.get(client(), url, opts)

  def post(url, body, opts \\ []), do: Tesla.post(client(), url, body, opts)
end

defmodule Cgc2046.Miniprogram.WechatClient do
  @moduledoc """
  微信小程序 SDK client 宿主（运行时配置 → WeChat.build_client 动态模块）。

  - 首次使用时按 :miniprogram_platforms 的 wechat 配置构建 + 启动
    （WeChat.start_client：注册 Refresher 定时刷新 + TokenChecker 失效自愈；
    token 存 SDK ETS，WeChat.Storage.Cache）。
  - 未配置（config 缺 wechat 键或缺 appid/secret）→ {:error, :wechat_not_configured}。
  - 测试环境不启动全局 Refresher（防跨用例泄漏）；token 由测试直接种
    WeChat.Storage.Cache（wechat_token_seed 注入约定）。

  Pattern 先例：payments/providers/wechat_pay.ex 的 build_cached_client
  （WeChat 宏编译期固化密钥，与 runtime 注入冲突 → 动态 build_client +
  :persistent_term 按配置指纹缓存）。
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

            with {:ok, module} <-
                   WeChat.build_client(client_module,
                     app_type: :mini_program,
                     appid: appid,
                     appsecret: secret,
                     requester: Cgc2046.Miniprogram.WechatRequester
                   ) do
              maybe_start(module, fingerprint)
              :persistent_term.put({__MODULE__, fingerprint}, module)
              {:ok, module}
            else
              {:error, reason} ->
                raise "wechat mini program client build failed: #{inspect(reason)}"
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
  # dev 未配真实 appid 时 Refresher 每 60s 打一次刷新失败 warning——已知噪音。
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
