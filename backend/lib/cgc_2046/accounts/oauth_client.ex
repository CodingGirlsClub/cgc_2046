defmodule Cgc2046.Accounts.OAuthClient do
  @moduledoc """
  OAuth 2.1 客户端（RFC 7591 动态注册 + 打包路径预注册公开 client，KTD1）。

  - **DCR**：`POST /oauth/register` 经 `:register` 动作落库（公开 client，PKCE-only，
    `token_endpoint_auth_method: "none"`，无 secret）。缺 `application_type` 的注册
    请求被接受（宿主不发送该字段——U2 实测）。
  - **回调限 loopback**（本期政策）：`:register` 拒绝一切非 loopback 回调
    （`127.0.0.1` / `::1` / `localhost`，任意端口）。库自带的 redirect_uri 校验
    只要求 https 或 http-loopback，不满足本政策，故执行点落在这里——`:register`
    是客户端行的唯一写入路径，任何 HTTP 层绕过都会在数据层被拒。人工批准非
    loopback 申请为后续工作（需另行定义批准人、证据与审计），本期不做。
  - **打包路径**：`ensure_packaged_client/0`（seeds 调用）预注册固定 id 的公开
    client（`packaged_client_id/0`，U7 包内引用），首公里不依赖 DCR；回调同样限
    loopback（`127.0.0.1:19876/mcp/oauth/callback`，端口可变——RFC 8252 §7.3，
    U2 实测宿主回调形态）。
  - `cimd_url` / `last_used_at` 由库的 `ClientResource` 扩展消费（CIMD 行 GC；
    本服务器 CIMD 未启用，`cimd_url` 恒 nil），故必须声明。
  """

  @packaged_client_id "0199e5a2-7c3f-7a41-9b0e-2f5c8d1a4b60"
  @packaged_redirect_uris ["http://127.0.0.1:19876/mcp/oauth/callback"]
  @loopback_hosts ["127.0.0.1", "::1", "localhost"]

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.Oauth2Server.ClientResource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Accounts

  attributes do
    uuid_v7_primary_key(:id)

    attribute(:client_name, :string,
      allow_nil?: false,
      public?: true,
      description: "客户端显示名（DCR client_name 或打包路径固定名）"
    )

    attribute(:redirect_uris, {:array, :string},
      allow_nil?: false,
      public?: true,
      description: "注册的回调地址（限 loopback）"
    )

    attribute(:grant_types, {:array, :string},
      allow_nil?: true,
      public?: true,
      description: "授权类型（本服务器只发 authorization_code / refresh_token）"
    )

    attribute(:response_types, {:array, :string},
      allow_nil?: true,
      public?: true,
      description: "响应类型（恒 code）"
    )

    attribute(:token_endpoint_auth_method, :string,
      allow_nil?: true,
      public?: true,
      description: "令牌端点认证方式（公开 client 恒 none）"
    )

    attribute(:scope, :string,
      allow_nil?: true,
      public?: true,
      description: "注册时同意的 scope 串"
    )

    attribute(:cimd_url, :string,
      allow_nil?: true,
      public?: true,
      description: "CIMD 元数据 URL（本服务器未启用 CIMD，恒 nil）"
    )

    attribute(:last_used_at, :utc_datetime_usec,
      allow_nil?: true,
      public?: true,
      description: "最近一次在授权/令牌路径被引用的时间（库扩展触碰）"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  postgres do
    table("oauth_clients")
    repo(Cgc2046.Repo)
  end

  actions do
    default_accept([])
    defaults([:read])

    create :register do
      description("RFC 7591 动态客户端注册（公开 client；回调限 loopback）")

      accept([
        :client_name,
        :redirect_uris,
        :grant_types,
        :response_types,
        :token_endpoint_auth_method,
        :scope
      ])

      change(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :redirect_uris) do
          uris when is_list(uris) ->
            if Enum.all?(uris, &loopback_redirect_uri?/1) do
              changeset
            else
              Ash.Changeset.add_error(changeset,
                field: :redirect_uris,
                message:
                  "only loopback redirect URIs are accepted (127.0.0.1 / ::1 / localhost, any port)"
              )
            end

          _ ->
            changeset
        end
      end)
    end
  end

  policies do
    # 协议端点（register/authorize/token）经库以 AshAuthentication 交互上下文调用
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end
  end

  @doc "打包路径预注册 client 的固定 id（U7 包内引用；seeds 落库）。"
  @spec packaged_client_id() :: String.t()
  def packaged_client_id, do: @packaged_client_id

  @doc "打包路径预注册 client 的回调地址（opencode loopback 回调，端口可变）。"
  @spec packaged_redirect_uris() :: [String.t()]
  def packaged_redirect_uris, do: @packaged_redirect_uris

  @doc "回调地址是否 loopback（非 loopback 注册一律拒绝，本期政策）。"
  @spec loopback_redirect_uri?(term()) :: boolean()
  def loopback_redirect_uri?(uri) when is_binary(uri) do
    case URI.new(uri) do
      {:ok, %URI{host: host}} -> host in @loopback_hosts
      _ -> false
    end
  end

  def loopback_redirect_uri?(_), do: false

  @doc """
  预注册打包路径公开 client（幂等，seeds 与测试同一形态）：存在即复用。

  注册内容 = PKCE-only 公开 client + loopback 回调 + 平台单 scope；无 secret。
  """
  @spec ensure_packaged_client() :: {:ok, __MODULE__.t()} | {:error, term()}
  def ensure_packaged_client do
    case Ash.get(__MODULE__, @packaged_client_id, authorize?: false) do
      {:ok, client} ->
        {:ok, client}

      _ ->
        __MODULE__
        |> Ash.Changeset.for_create(
          :register,
          %{
            client_name: "CGC 学习空间",
            redirect_uris: @packaged_redirect_uris,
            grant_types: ["authorization_code", "refresh_token"],
            response_types: ["code"],
            token_endpoint_auth_method: "none",
            scope: Cgc2046.Oauth2Server.scope()
          },
          authorize?: false
        )
        |> Ash.Changeset.force_change_attribute(:id, @packaged_client_id)
        |> Ash.create()
    end
  end

  admin do
    # #113 ops 面优化：导航分组（OAuth client 行（注册回调/名称；无 secret））
    resource_group(:accounts)
  end
end
