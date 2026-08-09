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

  每用户可同时持有多个 token（D-D4 定稿：撤销粒度按 token），
  active 上限 10 个（`@max_active_tokens_per_user`，防无限铸造；已撤销不计）。
  """
  # 每用户 active token 上限（review 修复：无速率限制中间件可适配按用户计数，故在资源层守卫）
  @max_active_tokens_per_user 10
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
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
      # arguments 建 key，换备注名即绕过；有效治理是按用户计数）。已撤销不计。
      # 须在 user_id 落 changeset 之后执行，故排在上一 change 之后。
      change(fn changeset, _context ->
        actor_id = Ash.Changeset.get_attribute(changeset, :user_id)

        active_count =
          __MODULE__
          |> Ash.Query.filter(user_id == ^actor_id and is_nil(revoked_at))
          |> Ash.count!(authorize?: false)

        if active_count >= @max_active_tokens_per_user do
          Ash.Changeset.add_error(
            changeset,
            Ash.Error.Changes.InvalidAttribute.exception(
              field: :name,
              message:
                "active connection token limit reached (#{@max_active_tokens_per_user}); revoke an unused token first"
            )
          )
        else
          changeset
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
  按明文 token 校验并返回所属 user；无效/已撤销返回 `:error`。

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
        touch_last_used(token)

        case Ash.get(Cgc2046.Accounts.User, token.user_id, authorize?: false) do
          {:ok, user} -> {:ok, user}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def validate_token(_), do: :error

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
end
