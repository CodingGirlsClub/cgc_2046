defmodule Cgc2046.Accounts.OAuthRefreshToken do
  @moduledoc """
  OAuth 2.1 刷新令牌 = **一条授权的载体**（token family / 轮换链，KTD8）。

  安全约束（同 `Cgc2046.Mcp.Token` 范式）：

  - 只存 SHA256 `token_hash`，不落明文；明文仅在签发响应里一次性交付
  - 撤销 = 整条链置 `revoked_at`（保留审计行；access token 是自包含 JWT，
    撤销 access 无状态可改，因此**资源服务器每次调用都要回查本表的活跃性**
    ——只撤销 access 会被宿主静默 refresh 绕过，U2 实测）
  - 轮换（`:rotate`，含重用检测）+ 链式过期（`expires_at` 随轮换前推，
    = 90 天滚动闲置窗口，见 `Cgc2046.Oauth2Server`）

  ## 授权 = 一条链

  同一 (user, client) 的一条轮换链共享 `chain_id`（`Token.complete_rotation/…`
  继承父行 chain_id），因此：

  - 活跃性判定 = 链上存在未撤销、未轮换、未过期的一行（`verify_live/1`）
  - 撤销粒度 = 链（`revoke_authorization/2`，供 web 撤销面调用；RFC 7009
    `/oauth/revoke` 路径由库按 refresh hash 级联整链）
  - 最近使用 = 链上当前行的 `last_used_at`（每次 MCP 调用经 `verify_live/1` 触碰，
    与 `Mcp.Token.last_used_at` 同源语义，供首公里「已连接」判定，KTD3/U5）

  `generation` 从 0 起每次轮换 +1（库不设上限，需要时由产品侧策略约束）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.Oauth2Server.RefreshTokenResource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Accounts

  require Ash.Query

  attributes do
    # 库预分配新行 id 以把「校验 + 轮换」压成一条 filtered UPDATE，
    # 故主键必须可写（见 RefreshTokenResource.Verifier）。
    attribute(:id, :uuid_v7,
      primary_key?: true,
      allow_nil?: false,
      writable?: true,
      public?: true,
      default: &Ash.UUIDv7.generate/0
    )

    attribute(:token_hash, :string,
      allow_nil?: false,
      public?: true,
      description: "刷新令牌的 SHA256 哈希（不存明文）"
    )

    attribute(:client_id, :uuid_v7,
      allow_nil?: false,
      public?: true,
      description: "OAuth client id"
    )

    attribute(:user_id, :uuid,
      allow_nil?: false,
      public?: true,
      description: "授权人（全局用户）ID"
    )

    attribute(:scope, :string,
      allow_nil?: false,
      public?: true,
      description: "授权 scope"
    )

    attribute(:resource_uri, :string,
      allow_nil?: false,
      public?: true,
      description: "授权受众（RFC 8707；= Oauth2Server.resource_url/0）"
    )

    attribute(:expires_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      description: "过期时间（每次轮换前推 = 滚动闲置窗口）"
    )

    attribute(:chain_id, :uuid_v7,
      allow_nil?: false,
      public?: true,
      description: "轮换链 id（= 首个授权行的自身 id）"
    )

    attribute(:generation, :integer,
      allow_nil?: false,
      public?: true,
      default: 0,
      description: "轮换代数（初次签发 0）"
    )

    attribute(:rotated_to_id, :uuid_v7,
      allow_nil?: true,
      public?: true,
      description: "被轮换到的后继行 id（null = 链上当前行）"
    )

    attribute(:rotated_at, :utc_datetime_usec,
      allow_nil?: true,
      public?: true,
      description: "轮换时间"
    )

    attribute(:revoked_at, :utc_datetime_usec,
      allow_nil?: true,
      public?: true,
      description: "撤销时间（null = 有效；撤销按整链级联）"
    )

    attribute(:last_used_at, :utc_datetime_usec,
      allow_nil?: true,
      public?: true,
      writable?: false,
      description: "最近一次 MCP 调用时间（verify_live/1 触碰，同 Mcp.Token 语义）"
    )
  end

  identities do
    identity(:by_token_hash, [:token_hash])
  end

  postgres do
    table("oauth_refresh_tokens")
    repo(Cgc2046.Repo)

    custom_indexes do
      # 鉴权热路径索引：每次 MCP 调用经 verify_live/1 按 (user_id, client_id)
      # 回查链上活跃行；无索引时随该用户授权历史增长线性劣化（列表与撤销
      # 路径的收窄读同样命中）。表由本分支新建、线上为空，普通 CREATE INDEX
      # 不锁既有数据。
      index([:user_id, :client_id])
    end
  end

  actions do
    default_accept([])
    defaults([:read, :destroy])

    create :issue do
      description("签发刷新令牌（首次授权与每次轮换各一行，同 chain_id）")

      accept([
        :id,
        :chain_id,
        :generation,
        :token_hash,
        :client_id,
        :user_id,
        :scope,
        :resource_uri,
        :expires_at
      ])
    end

    update :rotate do
      description("轮换：原子占用旧行（含重用/撤销/过期过滤在 RotateRefreshToken 内）")
      argument(:rotated_to_id, :uuid_v7, allow_nil?: false)
      accept([])

      change(AshAuthentication.Oauth2Server.Changes.RotateRefreshToken)
    end

    update :revoke do
      description("撤销（幂等；撤销粒度 = 整条链，调用方按 chain_id/user+client 过滤）")
      accept([])

      change(atomic_update(:revoked_at, expr(now())))
    end

    update :touch_last_used do
      description("内部：触碰 last_used_at（鉴权回查路径，bypass policy 调用）")
      require_atomic?(false)

      change(set_attribute(:last_used_at, &DateTime.utc_now/0))
    end
  end

  policies do
    # 协议端点与鉴权回查路径经库/内部函数以 bypass 上下文调用
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end

    policy action(:touch_last_used) do
      authorize_if(always())
    end
  end

  @doc """
  OAuth 访问令牌的**活跃性回查**（KTD8：签名校验之外，每次调用都回查）。

  `{:ok, user_id}` 当且仅当该 (user, client) 授权仍活跃——链上存在未撤销、
  未轮换、未过期的一行；命中即触碰 `last_used_at`（最近使用时间，供首公里
  「已连接」判定）。

  撤销（`revoke_authorization/2` 或 RFC 7009 `/oauth/revoke`）与闲置超过窗口
  （`expires_at` 不再前推）都在此塌缩为 `:error`——**不依赖 access token 自然
  过期**，撤销后下一次调用即失效。
  """
  @spec verify_live(map()) :: {:ok, String.t()} | :error
  def verify_live(%{"sub" => user_id, "client_id" => client_id})
      when is_binary(user_id) and is_binary(client_id) and user_id != "" and client_id != "" do
    now = DateTime.utc_now()

    case __MODULE__
         |> Ash.Query.filter(
           user_id == ^user_id and client_id == ^client_id and is_nil(revoked_at) and
             is_nil(rotated_to_id) and expires_at > ^now
         )
         |> Ash.read_one(authorize?: false) do
      {:ok, %__MODULE__{} = row} ->
        touch_last_used(row)
        {:ok, row.user_id}

      _ ->
        :error
    end
  end

  def verify_live(_claims), do: :error

  @doc """
  活跃谓词（内存判定）：未撤销 + 未过期。

  与 `verify_live/1` 的数据库过滤条件逐条同构——**改一处必须同步另一处**；
  读模型与回执侧（`Cgc2046.Accounts.OAuthAuthorizations`）经此单源判定，
  避免两份实现漂移导致列表 status 与 /mcp 的 401 判定分叉。
  """
  def live?(row, now \\ DateTime.utc_now())

  def live?(%__MODULE__{revoked_at: nil, expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  def live?(_row, _now), do: false

  @doc """
  撤销一条授权（整链级联：该 user + client 的全部未撤销行）。

  web 撤销面（U5：MCP 页「已授权应用」列表 + 撤销）与测试的撤销回路入口；
  RFC 7009 `/oauth/revoke`（宿主自撤销）走库的按 hash 级联路径，两条路径
  都落在同一 `:revoke` 动作上。
  """
  @spec revoke_authorization(String.t(), String.t()) :: :ok | :error
  def revoke_authorization(user_id, client_id)
      when is_binary(user_id) and is_binary(client_id) do
    __MODULE__
    |> Ash.Query.filter(user_id == ^user_id and client_id == ^client_id and is_nil(revoked_at))
    |> Ash.bulk_update(:revoke, %{},
      return_records?: false,
      return_errors?: true,
      notify?: false,
      authorize?: false
    )
    |> case do
      %Ash.BulkResult{status: :success} -> :ok
      _ -> :error
    end
  end

  # 触碰失败（并发撤销/轮换等）不影响鉴权主路径
  defp touch_last_used(row) do
    row
    |> Ash.Changeset.for_update(:touch_last_used, %{}, authorize?: false)
    |> Ash.update()
    |> case do
      {:ok, _} -> :ok
      _ -> :ok
    end
  end

  admin do
    # #113 ops 面优化：导航分组（OAuth 授权链（每行一个刷新令牌；撤销粒度=链））
    resource_group(:accounts)
  end
end
