defmodule Cgc2046.MiniprogramFixtures do
  @moduledoc """
  小程序平台登录测试 fixture（Phase 1 身份基座）。

  - 三平台 code2session 响应构造（wechat 扁平 errcode / tt err_no+data / xhs code+data+open_id）
  - 手机号负载加密：AES-128-CBC（key = Base64 解码的 session_key）+ 随机 IV + PKCS7，
    与平台官方算法一致——客户端走真实解密路径，测试即端到端覆盖加解密。
  - Req.Test stub：断言请求参数携带 runtime config 注入的 appid/secret（防硬编码回退）。

  stub 进程模型：Req.Test ownership 沿 `$callers` 解析——测试进程直接调用、
  `Task.async` 并发场景均无需显式 allow。
  """

  import ExUnit.Assertions

  alias Cgc2046.MiniprogramFixtures.Barrier

  @stub_name Cgc2046.MiniprogramClientStub

  def stub_name, do: @stub_name

  # ── session_key / 加密负载 ─────────────────────────────────────────────

  @doc "生成平台风格的 session_key（Base64 编码的 16 字节随机数）。"
  def new_session_key, do: Base.encode64(:crypto.strong_rand_bytes(16))

  @doc """
  按平台规范加密手机号负载，返回 `{encrypted_data, iv}`（均 Base64）。

  与微信/抖音/小红书 getPhoneNumber 加密数据格式一致：
  AES-128-CBC，密钥为 Base64 解码的 session_key，PKCS7 填充。
  """
  def encrypt_phone(session_key_b64, payload) when is_map(payload) do
    key = Base.decode64!(session_key_b64)
    iv = :crypto.strong_rand_bytes(16)

    # 显式 padding 选项（boolean 形式对非块对齐输入会静默截断）
    encrypted =
      :crypto.crypto_one_time(:aes_128_cbc, key, iv, Jason.encode!(payload),
        encrypt: true,
        padding: :pkcs_padding
      )

    {Base.encode64(encrypted), Base.encode64(iv)}
  end

  @doc """
  构造平台 getPhoneNumber 解密前的明文负载。

  - 默认带 countryCode "86"（微信/抖音均返回该字段）
  - `watermark_appid: appid` 附加微信 watermark（客户端校验其与本应用 appid 一致）
  """
  def phone_payload(phone, opts \\ []) do
    %{
      "phoneNumber" => Keyword.get(opts, :phone_number, phone),
      "purePhoneNumber" => phone,
      "countryCode" => Keyword.get(opts, :country_code, "86")
    }
    |> maybe_watermark(Keyword.get(opts, :watermark_appid))
  end

  defp maybe_watermark(payload, nil), do: payload

  defp maybe_watermark(payload, appid),
    do: Map.put(payload, "watermark", %{"appid" => appid, "timestamp" => 1_754_601_600})

  # ── code2session 响应构造 ──────────────────────────────────────────────

  @doc "平台 code2session 成功响应体（attrs: %{openid, session_key, unionid?}）。"
  def code2session_body(:wechat, attrs) do
    %{"openid" => attrs.openid, "session_key" => attrs.session_key}
    |> maybe_put("unionid", attrs[:unionid])
  end

  def code2session_body(:tt, attrs) do
    data =
      %{"openid" => attrs.openid, "session_key" => attrs.session_key}
      |> maybe_put("unionid", attrs[:unionid])

    %{"err_no" => 0, "err_tips" => "ok", "data" => data}
  end

  # xhs 在线端点实测信封（2026-08-08 curl /api/rmp/session 错误样本：
  # {"success":false,"msg":"应用访问令牌不匹配","data":null,"code":410101}）。
  # 官方《登录态管理》：小红书暂不提供 unionid → 不构造 union_id。
  # data 内字段名用社区样本的 openid（官方文档写 open_id；客户端两者都接）。
  def code2session_body(:xhs, attrs) do
    %{
      "code" => 0,
      "success" => true,
      "msg" => "success",
      "data" => %{"openid" => attrs.openid, "session_key" => attrs.session_key}
    }
  end

  @doc "xhs /api/rmp/token 响应体（两步流程第一步；access_token 值固定便于跨调用断言）。"
  def xhs_token_body do
    %{
      "code" => 0,
      "success" => true,
      "msg" => "success",
      "data" => %{"access_token" => xhs_access_token(), "expires_in" => 10_800}
    }
  end

  def xhs_access_token, do: "xhs-test-access-token"

  @doc "平台 code2session 失败响应体（无效 code）。"
  def code2session_error_body(:wechat), do: %{"errcode" => 40_029, "errmsg" => "invalid code"}
  def code2session_error_body(:tt), do: %{"err_no" => 40_004, "err_tips" => "invalid code"}

  def code2session_error_body(:xhs),
    do: %{"code" => 400_001, "success" => false, "msg" => "invalid code", "data" => nil}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── Req.Test stub ──────────────────────────────────────────────────────

  @doc """
  注册 code2session stub。`responses` 为 `%{platform => body | (conn -> body)}`，
  可只给部分平台（未覆盖的平台请求会 KeyError 失败——测试应只触发已 stub 的平台）。

  每个命中请求都会断言：host/path 正确且参数携带 config 注入的 appid/secret/code。
  """
  def stub_code2session(responses) when is_map(responses) do
    Req.Test.stub(@stub_name, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      platform = detect_platform!(conn)
      conn = assert_session_request!(platform, conn)

      body =
        case platform do
          # xhs 两步流程：token 步自动应答（响应体只需配 session 步的）
          :xhs_token ->
            xhs_token_body()

          _ ->
            case Map.fetch!(responses, platform) do
              fun when is_function(fun, 1) -> fun.(conn)
              static -> static
            end
        end

      Req.Test.json(conn, body)
    end)
  end

  defp detect_platform!(conn) do
    case {conn.host, conn.request_path} do
      {"api.weixin.qq.com", "/sns/jscode2session"} -> :wechat
      {"developer.toutiao.com", "/api/apps/v2/jscode2session"} -> :tt
      {"miniapp.xiaohongshu.com", "/api/rmp/token"} -> :xhs_token
      {"miniapp.xiaohongshu.com", "/api/rmp/session"} -> :xhs
      other -> raise "unexpected platform request: #{inspect(other)}"
    end
  end

  defp assert_session_request!(:wechat, conn) do
    config = platform_config!(:wechat)

    assert conn.query_params["appid"] == config.appid,
           "wechat appid 应来自 runtime config，实际 #{conn.query_params["appid"]}"

    assert conn.query_params["secret"] == config.secret
    assert is_binary(conn.query_params["js_code"])
    assert conn.query_params["grant_type"] == "authorization_code"
    conn
  end

  defp assert_session_request!(:tt, conn) do
    config = platform_config!(:tt)
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    params = Jason.decode!(raw)

    assert params["appid"] == config.appid,
           "tt appid 应来自 runtime config，实际 #{params["appid"]}"

    assert params["secret"] == config.secret
    assert is_binary(params["code"])
    conn
  end

  # xhs 两步流程：token 调用验 config 注入的 app_id/app_secret；
  # session 调用验 app_id/code 且 access_token 必须是 token 步签发的那个（跨调用接线证明）。
  defp assert_session_request!(:xhs_token, conn) do
    config = platform_config!(:xhs)
    assert conn.query_params["app_id"] == config.appid
    assert conn.query_params["app_secret"] == config.secret
    assert conn.query_params["grant_type"] == "client_credential"
    conn
  end

  defp assert_session_request!(:xhs, conn) do
    config = platform_config!(:xhs)
    assert conn.query_params["app_id"] == config.appid

    assert conn.query_params["access_token"] == xhs_access_token(),
           "xhs session 调用应携带 token 步签发的 access_token"

    assert is_binary(conn.query_params["code"])
    conn
  end

  defp platform_config!(platform) do
    :cgc_2046
    |> Application.get_env(:miniprogram_platforms, %{})
    |> Map.fetch!(platform)
  end

  # ── 并发栅栏（竞态测试）─────────────────────────────────────────────────
  #
  # Barrier 实现见 `Cgc2046.MiniprogramFixtures.Barrier`
  # （test/support/miniprogram_fixtures/barrier.ex，AGENTS.md 模块单文件规则）。

  @doc """
  包装响应构造器：每个调用到达后先 `Barrier.arrive/1` 对齐（闭包持有 barrier pid，
  stub 在 Task 进程内执行也指向同一栅栏），全部到达后再返回原响应。

  用法：`barrier = start_supervised!({Cgc2046.MiniprogramFixtures.Barrier, n})`
  """
  def barrier_wrap(barrier) do
    fn body_fun ->
      fn conn ->
        Barrier.arrive(barrier)
        body_fun.(conn)
      end
    end
  end
end
