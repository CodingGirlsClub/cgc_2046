defmodule Cgc2046.Mcp.Token do
  @moduledoc """
  连接 token 资源（MCP Bearer token，D13 / D-D4）。

  与网站登录 token（`Cgc2046.Accounts.Token`，httpOnly cookie JWT）是两种不同凭证：
  - 本资源：用户 OpenClacky/opencode/omp 等 MCP 客户端调 `/mcp` 端点用的 Bearer token
  - 绑用户、不绑工作区；可访问用户加入的多个 Workspace，租户由每次调用的
    `workspace_id` 参数判定（D6/D12）

  安全约束：
  - 库中只存 SHA256 `token_hash`，不落明文（复刻 Invitation token_hash 模式）
  - 明文仅 `:issue` 创建时经 `metadata.plain_token` 一次性返回
  - 撤销 = 置 `revoked_at`（保留审计行，不删记录）
  - 连续 90 天未使用即失效（滚动过期 `@idle_expiry_days`，#222；正常使用不断，
    过期为惰性判定，行保留原样不置 `revoked_at`）

  每用户可同时持有多个 token（D-D4 定稿：撤销粒度按 token），
  active 上限 10 个（`@max_active_tokens_per_user`，防无限铸造；active = 未撤销
  且未闲置过期，二者均不计入上限）。
  """
  # 每用户 active token 上限（review 修复：无速率限制中间件可适配按用户计数，故在资源层守卫）
  @max_active_tokens_per_user 10
  # 滚动过期窗口（#222）：连续 90 天未使用即失效；正常使用不断，无需重签
  @idle_expiry_days 90
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Mcp

  require Ash.Query

  attributes do
    uuid_primary_key(:id)

    attribute(:token_hash, :string,
      allow_nil?: false,
      public?: true,
      description: "连接 token 的 SHA256 哈希（不存明文）"
    )

    attribute(:name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 80],
      description: "用户可读的 token 备注（如设备名）"
    )

    attribute(:user_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属用户（全局）ID"
    )

    attribute(:last_used_at, :utc_datetime,
      allow_nil?: true,
      public?: true,
      writable?: false,
      description: "最近一次 MCP 调用时间（validate_token 触碰）"
    )

    attribute(:revoked_at, :utc_datetime,
      allow_nil?: true,
      public?: true,
      writable?: false,
      description: "撤销时间（null = 有效）"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:user, Cgc2046.Accounts.User, define_attribute?: false)
  end

  identities do
    identity(:unique_token_hash, [:token_hash])
  end

  postgres do
    table("mcp_tokens")
    repo(Cgc2046.Repo)
  end

  actions do
    default_accept([])
    defaults([:read])

    create :issue do
      description("签发连接 token（仅本人；明文仅创建时经 metadata.plain_token 返回一次）")
      accept([:name])

      # 归属当前 actor；writable?: false 用 force_change_attribute 绕过（同 Invitation 范式）
      change(fn changeset, context ->
        case context.actor do
          %{id: actor_id} ->
            Ash.Changeset.force_change_attribute(changeset, :user_id, actor_id)

          _ ->
            changeset
        end
      end)

      # 每用户 active token 上限（防无限铸造：无 RateLimit 适配——其中间件按
      # arguments 建 key，换备注名即绕过；有效治理是按用户计数）。active = 未撤销
      # 且未闲置过期。须在 user_id 落 changeset 之后执行，故排在上一 change 之后。
      change(fn changeset, _context ->
        actor_id = Ash.Changeset.get_attribute(changeset, :user_id)

        # 未认证 actor（user_id 未落，policy 层将拒绝）：跳过计数查询，
        # 避免 user_id == nil 进 filter 的运行期 warning（#223 advisory A2）
        if is_nil(actor_id) do
          changeset
        else
          # 闲置过期不计入上限（#226：死行占位迫使用户手动撤销才能新签）。
          # SQL 谓词与 idle_expired?/1 严格对齐：cutoff = now - @idle_expiry_days 天，
          # 锚点（last_used_at，从未使用回退 inserted_at）> cutoff 才算 active——
          # 恰 -90 天（锚点 == cutoff）被排除，同 Elixir 侧 DateTime.diff >= 90 判过期。
          cutoff = DateTime.add(DateTime.utc_now(), -@idle_expiry_days, :day)

          active_count =
            __MODULE__
            |> Ash.Query.filter(
              user_id == ^actor_id and is_nil(revoked_at) and
                ((is_nil(last_used_at) and inserted_at > ^cutoff) or
                   (not is_nil(last_used_at) and last_used_at > ^cutoff))
            )
            |> Ash.count!(authorize?: false)

          if active_count >= @max_active_tokens_per_user do
            Ash.Changeset.add_error(
              changeset,
              Ash.Error.Changes.InvalidAttribute.exception(
                field: :name,
                message:
                  "active connection token limit reached (#{@max_active_tokens_per_user}; active = unrevoked and not idle-expired); revoke an unused token first"
              )
            )
          else
            changeset
          end
        end
      end)

      # 生成 token 并存储 hash；明文仅通过 metadata 一次性返回，不落库
      change(fn changeset, _context ->
        token = "cgc_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
        token_hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

        changeset
        |> Ash.Changeset.change_attribute(:token_hash, token_hash)
        |> Ash.Changeset.put_context(:plain_token, token)
      end)

      change(
        after_action(fn changeset, token, _context ->
          plain = changeset.context[:plain_token]
          {:ok, Ash.Resource.put_metadata(token, :plain_token, plain)}
        end)
      )

      metadata(:plain_token, :string,
        allow_nil?: false,
        description: "明文连接 token（仅创建时返回一次，不落库）"
      )
    end

    update :revoke do
      description("撤销连接 token（仅本人；置 revoked_at，保留审计行）")
      require_atomic?(false)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          if is_nil(cs.data.revoked_at) do
            cs
          else
            Ash.Changeset.add_error(
              cs,
              Ash.Error.Changes.InvalidAttribute.exception(
                field: :revoked_at,
                message: "Token has already been revoked"
              )
            )
          end
        end)
      end)

      # 原子条件：UPDATE ... WHERE revoked_at IS NULL。before_action 读的是内存副本，
      # 并发/陈旧 struct 会绕过它——DB 级 WHERE 兜底，竞态失败者影响 0 行 → StaleRecord，
      # 不再静默覆盖审计时间戳（同 pending_operation.ex MEDIUM-1 范式）
      change(fn changeset, _context ->
        Ash.Changeset.filter(changeset, expr(is_nil(revoked_at)))
      end)

      change(set_attribute(:revoked_at, &DateTime.utc_now/0))
    end

    # validate_token 内部使用：按 hash 查 + 触碰 last_used_at。
    # 不做 policy 鉴权（MCP 鉴权前置路径，token 本身即凭证），调用方负责控制暴露面。
    update :touch_last_used do
      description("内部：触碰 last_used_at（bypass policy）")
      require_atomic?(false)
      change(set_attribute(:last_used_at, &DateTime.utc_now/0))
    end
  end

  policies do
    # 签发/读/撤：仅本人
    policy action(:issue) do
      authorize_if(actor_present())
    end

    policy action(:read) do
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action(:revoke) do
      authorize_if(expr(user_id == ^actor(:id)))
    end

    # 内部维护动作绕过 actor 检查（由 validate_token 以 authorize?: false 调用）
    policy action(:touch_last_used) do
      authorize_if(always())
    end
  end

  @doc """
  列出当前 actor 的连接 token，按签发时间新→旧排序。

  仅返回本人 token（policy `read` 约束 `user_id == actor`，无需重复过滤）。
  """
  @spec list_for(Cgc2046.Accounts.User.t()) :: {:ok, [__MODULE__.t()]} | {:error, term()}
  def list_for(%{id: _} = actor) do
    __MODULE__
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read(actor: actor)
  end

  @doc """
  签发连接 token，返回 `{:ok, token, plain}`——明文仅此一次交付，不落库。

  - 未认证 actor（nil）返回 `{:error, %Ash.Error.Forbidden{}}`
  - active token 达 `@max_active_tokens_per_user` 上限返回 `{:error, %Ash.Error.Invalid{}}`
  """
  @spec issue(String.t(), Cgc2046.Accounts.User.t() | nil) ::
          {:ok, __MODULE__.t(), String.t()} | {:error, term()}
  def issue(name, actor) do
    case __MODULE__
         |> Ash.Changeset.for_create(:issue, %{name: name}, actor: actor)
         |> Ash.create() do
      {:ok, token} ->
        {:ok, token, token.__metadata__[:plain_token]}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  撤销连接 token（置 `revoked_at`，保留审计行）。

  - 本人 token → `{:ok, token}`
  - 他人 token / 不存在 id → `{:error, :not_found}`（统一塌缩，不泄露存在性）
  - 撤销失败（重复撤销 / 并发竞态败者）→ `{:error, {:invalid, error}}`
  """
  @spec revoke(term(), Cgc2046.Accounts.User.t()) ::
          {:ok, __MODULE__.t()} | {:error, :not_found} | {:error, {:invalid, term()}}
  def revoke(id, %{id: _} = actor) do
    with {:ok, token} <- Ash.get(__MODULE__, id, actor: actor),
         {:ok, revoked} <-
           token
           |> Ash.Changeset.for_update(:revoke, %{}, actor: actor)
           |> Ash.update() do
      {:ok, revoked}
    else
      # get 失败（他人 token / 不存在 id）统一塌缩为 :not_found，不泄露存在性。
      # Ash 3.31 的 Ash.get 对无权/不存在的记录统一返回
      # %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}（越权不暴露 Forbidden）。
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} -> {:error, :not_found}
      {:error, %Ash.Error.Forbidden{}} -> {:error, :not_found}
      # revoke action 失败（重复撤销 / 竞态败者）
      {:error, %Ash.Error.Invalid{} = error} -> {:error, {:invalid, error}}
      {:error, error} -> {:error, {:invalid, error}}
    end
  end

  @doc """
  按明文 token 校验并返回所属 user；无效/已撤销/连续闲置过期的 token 返回 `:error`。

  MCP 鉴权前置路径：token 本身即凭证，故绕 policy 查询（authorize?: false）。
  校验通过后异步触碰 `last_used_at`（失败不影响主路径）。
  """
  @spec validate_token(String.t()) :: {:ok, Cgc2046.Accounts.User.t()} | :error
  def validate_token(plain) when is_binary(plain) do
    hash = :crypto.hash(:sha256, plain) |> Base.encode16(case: :lower)

    case __MODULE__
         |> Ash.Query.filter(token_hash == ^hash and is_nil(revoked_at))
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        :error

      {:ok, token} ->
        if idle_expired?(token) do
          :error
        else
          touch_last_used(token)

          case Ash.get(Cgc2046.Accounts.User, token.user_id, authorize?: false) do
            {:ok, user} -> {:ok, user}
            _ -> :error
          end
        end

      _ ->
        :error
    end
  end

  def validate_token(_), do: :error

  # 滚动过期（#222）：连续 @idle_expiry_days 天未使用即失效，锚点取 last_used_at
  # （从未使用回退 inserted_at）。过期为派生状态，惰性判定不写 revoked_at（那是
  # 用户撤销动作的审计语义）；与无效/撤销统一塌缩 :error，不泄露存在性。
  defp idle_expired?(token) do
    anchor = token.last_used_at || token.inserted_at
    DateTime.diff(DateTime.utc_now(), anchor, :day) >= @idle_expiry_days
  end

  # issue 计数上限排除闲置过期（#226）：SQL 谓词须与本函数整天边界对齐（>= 90）。

  # 触碰失败（并发撤销等）不影响鉴权主路径
  defp touch_last_used(token) do
    token
    |> Ash.Changeset.for_update(:touch_last_used, %{}, authorize?: false)
    |> Ash.update()
    |> case do
      {:ok, _} -> :ok
      _ -> :ok
    end
  end

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪（默认全列横向爆炸；敏感/超大字段不列出）
    resource_group(:mcp)
    table_columns([:id, :name, :user_id, :last_used_at, :revoked_at, :inserted_at])
  end
end
