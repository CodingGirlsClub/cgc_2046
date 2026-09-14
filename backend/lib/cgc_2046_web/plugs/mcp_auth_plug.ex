defmodule Cgc2046Web.Plugs.McpAuthPlug do
  @moduledoc """
  MCP endpoint 双凭证鉴权（KTD8，D13 / plan P1.4 + opencode 接入）。

  两路凭证按**形态**分派（OAuth access token 是 JWT，静态连接 token 以 `cgc_`
  开头、不含 `.`），判定次序不影响结果，二者都落到 `conn.assigns[:current_user]`
  ——68 工具与 `Cgc2046.Mcp.Wrapper` 依赖该契约：

  - **OAuth 凭证**：`AshAuthentication.Oauth2Server.Jwt.verify/2` 校验签名/iss/aud/exp
    之外，**每次调用回查授权活跃性**（`Cgc2046.Accounts.OAuthRefreshToken.verify_live/1`）
    ——撤销与闲置即时生效，纯签名校验做不到（KTD8）；命中即触碰该授权的
    `last_used_at`（首公里「已连接」判定）。
  - **静态连接 token**：`Cgc2046.Mcp.Token.validate_token/1`（既有路径，零回归）。

  失败一律 401 + `WWW-Authenticate`（RFC 6750）+ `resource_metadata`（RFC 9728，
  宿主据此发现授权服务器；U2 实测宿主 401 → discovery → refresh 序列）。401 的
  错误码是 Bearer 语义的 `invalid_token`（撤销/闲置同形，不泄露凭证状态差异）；
  `invalid_grant` 属令牌端点语义，由 `/oauth/token` 的刷新失败返回（U2 实测：
  宿主以 invalid_grant 判定「需重新授权」）。

  ## 失败认证节流（#214）

  按 remote_ip 计**失败**认证次数（ETS 固定窗口，复用
  `Cgc2046Web.Plugs.RateLimit`；默认 20 次/15 分钟，app env
  `config :cgc_2046, Cgc2046Web.Plugs.McpAuthPlug, max_attempts:` 可调），
  超限后改 429 + `Retry-After`——防凭证暴力试探。有效凭证的成功认证不计数也不受
  节流影响（NAT 后的正常用户不被旁人拖累；U2 的自愈序列会频繁 401，不能堵死）。

  **分桶按凭证类型**（OAuth / 静态 token 各自一个 key，单点定义见
  `@failure_bucket_prefixes`）：一类凭证被试探打到 429，不会连带把另一类的正常
  调用判成 429（反之亦然）。
  """
  @behaviour Plug

  import Plug.Conn

  alias AshAuthentication.Phoenix.Oauth2Server.Errors
  alias Cgc2046.Accounts.OAuthRefreshToken
  alias Cgc2046.Oauth2Server

  @throttle_window_seconds 900
  @bearer_realm "cgc-2046-mcp"
  @invalid_token_description "authorization is missing, invalid, revoked, or expired"

  # 失败节流分桶 key 前缀（单点定义）：OAuth 失败与静态 token 失败互不污染。
  @failure_bucket_prefixes %{
    oauth: "rate:mcp-auth:oauth",
    token: "rate:mcp-auth:token"
  }

  @oauth_jwt_segments 3

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case presented_credential(conn) do
      {:oauth, token} -> authenticate_oauth(conn, token)
      {:token, token} -> authenticate_token(conn, token)
      # 无 / 畸形 Authorization：归静态 token 桶（历史节流键语义）。
      :none -> unauthorized(conn, :token)
    end
  end

  defp presented_credential(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         ["Bearer", token] <- String.split(header, " ", parts: 2),
         true <- token != "" do
      {credential_kind(token), token}
    else
      _ -> :none
    end
  end

  # OAuth access token = JWT（header.payload.signature）；其余按静态连接 token 处理。
  defp credential_kind(token) do
    if token |> String.split(".") |> length() == @oauth_jwt_segments, do: :oauth, else: :token
  end

  defp authenticate_oauth(conn, token) do
    with {:ok, claims} <- AshAuthentication.Oauth2Server.Jwt.verify(Oauth2Server, token),
         {:ok, user_id} <- OAuthRefreshToken.verify_live(claims),
         {:ok, user} <- Ash.get(Cgc2046.Accounts.User, user_id, authorize?: false) do
      conn
      |> assign(:current_user, user)
      |> assign(:mcp_credential, %{type: :oauth})
    else
      _ -> unauthorized(conn, :oauth)
    end
  end

  defp authenticate_token(conn, token) do
    case Cgc2046.Mcp.Token.validate_token(token) do
      {:ok, user} ->
        conn
        |> assign(:current_user, user)
        |> assign(:mcp_credential, %{type: :token})

      :error ->
        unauthorized(conn, :token)
    end
  end

  defp unauthorized(conn, credential_type) do
    key =
      Cgc2046Web.Plugs.RateLimit.key_for(
        Map.fetch!(@failure_bucket_prefixes, credential_type),
        conn
      )

    if Cgc2046Web.Plugs.RateLimit.check(
         key,
         max_attempts: max_attempts(),
         window_seconds: @throttle_window_seconds
       ) == :ok do
      conn
      |> put_resp_header("www-authenticate", challenge())
      |> send_resp(401, unauthorized_body())
      |> halt()
    else
      conn
      |> put_resp_header("retry-after", Integer.to_string(@throttle_window_seconds))
      |> send_resp(429, ~s({"error":"rate_limited"}))
      |> halt()
    end
  end

  # RFC 6750 质询 + RFC 9728 受保护资源元数据指针（宿主据此发现授权服务器）。
  defp challenge do
    Errors.bearer_challenge([
      {"realm", @bearer_realm},
      {"error", "invalid_token"},
      {"error_description", @invalid_token_description},
      {"resource_metadata", Errors.resource_metadata_url(Oauth2Server)}
    ])
  end

  defp unauthorized_body do
    Jason.encode!(%{
      "error" => "invalid_token",
      "error_description" => @invalid_token_description
    })
  end

  defp max_attempts,
    do:
      Application.get_env(:cgc_2046, __MODULE__, [])
      |> Keyword.get(:max_attempts, 20)
end
