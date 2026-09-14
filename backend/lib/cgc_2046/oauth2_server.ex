defmodule Cgc2046.Oauth2Server do
  @moduledoc """
  MCP OAuth 2.1 授权服务器配置（KTD1 / KTD2 / KTD8，opencode Desktop 接入）。

  ## 单一配置源

  `resource_url` 一处配置同时供给三处使用（KTD2：由单一配置源供给，不由请求
  host 推导）：

  - PRM 响应（RFC 9728 `/.well-known/oauth-protected-resource` 的 `resource`）
  - `/mcp` 401 的 `resource_metadata` 发现头（经
    `AshAuthentication.Phoenix.Oauth2Server.Errors.resource_metadata_url/2`）
  - 访问令牌受众（RFC 8707 `aud` 绑定 + 校验）

  `issuer_url` 同理供给 RFC 8414 元数据、授权响应 `iss`（RFC 9207）与令牌 `iss`。
  issuer = web 站点域（授权页要读 web 的 host-only 登录 cookie），resource 与
  宿主 `mcp.url` 同值（R13 零回归）；两个值都显式配置，测试/dev/prod 各取各值。

  `resource_url` 是**带路径**的 MCP 端点 URL（如 `https://api.example.com/mcp`）；
  PRM 文档本身落该 resource 所在 origin 的根路径（RFC 9728），路径消解在
  `Errors.resource_metadata_url/2` 内完成，无需另一处配置。

  ## scopes

  单粗粒度 scope（PRM 广告即宿主请求集合，细分无安全收益）。库默认 `scopes: []`
  且 `enforce_scopes?: true`——**不显式配置则任何 scope 都不可用**（授权请求一律
  `invalid_scope`），故此处必须给值，改动它等于改客户端可见面。

  ## 签名密钥

  独立于会话/OAuth2 之外的签名密钥，经专用 env 注入（`:oauth2_signing_secret`）；
  缺失即 raise（`validate_secrets!/0`），与会话密钥（`:token_signing_secret`）或
  Phoenix 会话签名（endpoint `secret_key_base`）同值也 raise——密钥复用会让令牌
  面与登录面互相放大。
  """

  # 单粗粒度 scope：PRM / AS 元数据 / 令牌 `scope` / 打包 client 注册同源取值。
  @scope "cgc"

  use AshAuthentication.Oauth2Server,
    otp_app: :cgc_2046,
    user_resource: Cgc2046.Accounts.User,
    issuer_url: {__MODULE__, :resolve_secret!, [:oauth2_issuer_url]},
    resource_url: {__MODULE__, :resolve_secret!, [:oauth2_resource_url]},
    signing_secret: {__MODULE__, :resolve_secret!, [:oauth2_signing_secret]},
    client_resource: Cgc2046.Accounts.OAuthClient,
    authorization_code_resource: Cgc2046.Accounts.OAuthAuthorizationCode,
    refresh_token_resource: Cgc2046.Accounts.OAuthRefreshToken,
    consent_resource: Cgc2046.Accounts.OAuthConsent,
    scopes: [@scope],
    # 非打包宿主（MCP 客户端一律先 DCR）自注册；打包路径用预注册的公开 client
    # （OAuthClient.packaged_client_id/0），首公里不依赖注册端点。
    dcr_enabled?: true,
    # CIMD（URL 形态 client_id）未启用：DCR 已覆盖宿主，CIMD 额外引入出站抓取面。
    cimd_enabled?: false,
    # refresh 生命周期 = 授权闲置窗口：每次刷新轮换都会把新行 expires_at 推到
    # now + 窗口，故「连续闲置超过窗口」即整条链无可用的未过期行（对齐既有连接
    # token 的 90 天滚动语义，见 Mcp.Token）。撤销时整条链置 revoked_at，即时失效。
    refresh_token_lifetime: {90, :days},
    # 授权页未登录时的落点（库以 302 + return_to 引导）。U4 接手授权页体验：
    # 把该值指向 web 登录页即可（登录态 cookie 在主域，见 KTD2）。
    sign_in_path: Application.compile_env(:cgc_2046, :oauth2_sign_in_path, nil)

  @doc "广告给宿主的唯一 scope（PRM / AS 元数据 / 令牌 `scope` 同源）。"
  @spec scope() :: String.t()
  def scope, do: @scope

  @doc """
  库的 secret 解析入口（MFA 形态 `{__MODULE__, :resolve_secret!, [config_key]}`）：
  `path`（`[:issuer_url]` 等）与 `server` 由库传入，此处按显式 key 取值。

  缺失即 raise：URL 与签名密钥都不设默认值——默认值等于静默用错域名、或静默
  复用别的密钥。
  """
  @spec resolve_secret!(any(), module(), atom()) :: String.t()
  def resolve_secret!(_path, _server, key), do: config!(key)

  @doc "读取一处 OAuth2 配置（缺失/空值即 raise）。"
  @spec config!(atom()) :: String.t()
  def config!(key) do
    case Application.fetch_env(:cgc_2046, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        value

      _ ->
        raise """
        OAuth2 configuration #{inspect(key)} is missing or empty.

        Set it in config/runtime.exs (prod: OAUTH2_ISSUER_URL /
        OAUTH2_RESOURCE_URL / OAUTH2_SIGNING_SECRET environment variables).
        """
    end
  end

  @doc """
  启动自检：签名密钥必须存在且不得与会话类密钥同值。

  由 `Cgc2046.Application.start/2` 调用——**缺失即启动失败**（而非首次签发时
  才炸），也不允许复用会话签名密钥（`TOKEN_SIGNING_SECRET` / SECRET_KEY_BASE）：
  同一把密钥同时签登录 token 与 OAuth access token，任一面的密钥泄露或轮换都会
  波及另一面。
  """
  @spec validate_secrets!() :: :ok
  def validate_secrets! do
    signing = config!(:oauth2_signing_secret)

    Enum.each(
      [
        {:token_signing_secret, Application.get_env(:cgc_2046, :token_signing_secret)},
        {:endpoint_secret_key_base, endpoint_secret_key_base()}
      ],
      fn {other_key, other_value} ->
        if is_binary(other_value) and other_value == signing do
          raise """
          oauth2_signing_secret must be an independent secret, but it equals #{other_key}.

          Set OAUTH2_SIGNING_SECRET to a dedicated random value
          (e.g. `mix phx.gen.secret`) — never reuse the session/login signing keys.
          """
        end
      end
    )

    :ok
  end

  defp endpoint_secret_key_base do
    :cgc_2046
    |> Application.get_env(Cgc2046Web.Endpoint, [])
    |> Keyword.get(:secret_key_base)
  end
end
