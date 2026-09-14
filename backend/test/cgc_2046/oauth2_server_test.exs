defmodule Cgc2046.Oauth2ServerTest do
  @moduledoc """
  OAuth2 授权服务器配置自检（KTD2/KTD8）：

  - 签名密钥：专用 env、缺失即启动失败（raise）、不得与会话类密钥同值
  - issuer / resource 单一配置源：PRM、401 发现头、令牌受众同源读取
  """
  use ExUnit.Case, async: false

  alias AshAuthentication.Oauth2Server.Metadata
  alias AshAuthentication.Phoenix.Oauth2Server.Errors
  alias Cgc2046.Oauth2Server

  setup do
    original = Application.fetch_env!(:cgc_2046, :oauth2_signing_secret)

    on_exit(fn -> Application.put_env(:cgc_2046, :oauth2_signing_secret, original) end)

    :ok
  end

  test "签名密钥缺失 → 启动自检 raise（不进入运行态）" do
    Application.delete_env(:cgc_2046, :oauth2_signing_secret)

    assert_raise RuntimeError, ~r/oauth2_signing_secret/, fn ->
      Oauth2Server.validate_secrets!()
    end

    # 同一缺失态下解析 secret 也 raise（不是静默取默认值）
    assert_raise RuntimeError, ~r/oauth2_signing_secret/, fn ->
      Oauth2Server.signing_secret()
    end
  end

  test "签名密钥与会话登录密钥（token_signing_secret）同值 → raise" do
    session_secret = Application.fetch_env!(:cgc_2046, :token_signing_secret)
    Application.put_env(:cgc_2046, :oauth2_signing_secret, session_secret)

    assert_raise RuntimeError, ~r/token_signing_secret/, fn ->
      Oauth2Server.validate_secrets!()
    end
  end

  test "签名密钥与 Phoenix 会话签名密钥（endpoint secret_key_base）同值 → raise" do
    endpoint_secret =
      :cgc_2046
      |> Application.fetch_env!(Cgc2046Web.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    Application.put_env(:cgc_2046, :oauth2_signing_secret, endpoint_secret)

    assert_raise RuntimeError, ~r/secret_key_base/, fn ->
      Oauth2Server.validate_secrets!()
    end
  end

  test "独立密钥通过启动自检" do
    assert :ok = Oauth2Server.validate_secrets!()
  end

  test "issuer / resource 显式配置；PRM 与 401 发现头同源读取同一配置" do
    assert Oauth2Server.issuer_url() == "http://localhost:4000"
    assert Oauth2Server.resource_url() == "http://localhost:4000/mcp"

    assert Errors.resource_metadata_url(Oauth2Server) ==
             "http://localhost:4000/.well-known/oauth-protected-resource"

    prm = Metadata.protected_resource(Oauth2Server)
    assert prm["resource"] == Oauth2Server.resource_url()
    assert prm["authorization_servers"] == [Oauth2Server.issuer_url()]

    assert Metadata.authorization_server(Oauth2Server)["issuer"] == Oauth2Server.issuer_url()
  end

  test "scope 显式配置（未配置则任何 scope 不可用——库默认空集 + enforce_scopes?）" do
    assert Oauth2Server.scopes() == [Oauth2Server.scope()]
    assert Oauth2Server.enforce_scopes?()
    assert Oauth2Server.dcr_enabled?()
    refute Oauth2Server.cimd_enabled?()
  end

  test "refresh 生命周期 = 90 天滚动闲置窗口（对齐既有连接 token 语义）" do
    assert Oauth2Server.refresh_token_lifetime() == 90 * 24 * 3600
  end
end
