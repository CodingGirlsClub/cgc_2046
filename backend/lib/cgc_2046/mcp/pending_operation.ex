defmodule Cgc2046.Mcp.PendingOperation do
  @moduledoc """
  高风险 MCP 工具确认流的 pending 操作（D8 two-tool 模式 / D-D3）。

  链路：高风险 tool 调用 → 建 pending（**不落业务库**）→ 返回
  `needs_confirmation: {pending_id, 摘要}` → 用户确认 → `confirm_operation(pending_id)`
  → 真正执行 + 落库 + 审计。**无 confirm 不落库。**

  状态机：pending → confirmed | cancelled | expired（读时派生，expires_at < now）。
  默认 10 分钟有效期（confirm 窗口），可在创建时覆盖。
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Mcp

  @default_ttl_seconds 600

  attributes do
    uuid_primary_key(:id)

    attribute(:user_id, :uuid,
      allow_nil?: false,
      public?: true,
      description: "发起人（全局用户）ID"
    )

    attribute(:tool, :string,
      allow_nil?: false,
      public?: true,
      description: "目标工具名（如 create_invitation）"
    )

    attribute(:params, :map,
      allow_nil?: false,
      default: %{},
      public?: true,
      description: "待执行参数（redact 后）"
    )

    attribute(:summary, :string,
      allow_nil?: false,
      public?: true,
      description: "给用户确认用的操作摘要"
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      constraints: [one_of: [:pending, :confirmed, :cancelled]],
      description: "确认状态"
    )

    attribute(:expires_at, :utc_datetime,
      allow_nil?: false,
      public?: true,
      description: "确认截止（默认创建后 10 分钟）"
    )

    attribute(:resolved_at, :utc_datetime,
      allow_nil?: true,
      public?: true,
      description: "确认/取消时间"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:user, Cgc2046.Accounts.User, define_attribute?: false)
  end

  postgres do
    table("mcp_pending_operations")
    repo(Cgc2046.Repo)
  end

  calculations do
    # 读时派生过期：pending 且 expires_at < now 视为 expired（不落库，同 Invitation 范式）
    calculate(
      :effective_status,
      :string,
      {Cgc2046.Mcp.PendingOperation.EffectiveStatus, []},
      public?: true
    )
  end

  actions do
    default_accept([])
    defaults([:read])

    create :pend do
      description("创建 pending 操作（系统内部使用）")
      accept([:user_id, :tool, :params, :summary])

      change(fn changeset, _context ->
        ttl =
          Application.get_env(:cgc_2046, :mcp_confirmation_ttl_seconds, @default_ttl_seconds)

        Ash.Changeset.change_attribute(
          changeset,
          :expires_at,
          DateTime.add(DateTime.utc_now(), ttl, :second)
        )
      end)
    end

    update :confirm do
      description("确认执行（仅本人、pending 且未过期；原子条件更新，并发双确认只有一个成功）")
      require_atomic?(false)

      change(fn changeset, _context ->
        # expires_at 预检（友好错误）；status 竞争由下方 DB 级 WHERE 条件兜底（MEDIUM-1）
        Ash.Changeset.before_action(changeset, fn cs ->
          now = DateTime.utc_now()

          cond do
            cs.data.status != :pending ->
              invalid(cs, "Operation is not pending (status: #{cs.data.status})")

            DateTime.compare(cs.data.expires_at, now) == :lt ->
              invalid(cs, "Operation has expired")

            true ->
              cs
          end
        end)
      end)

      # 原子条件：UPDATE ... WHERE status = 'pending'；并发下影响行数为 0 → StaleRecord
      # （require_atomic? false 允许 before_action，filter 仍编入 UPDATE 的 WHERE 子句）
      change(fn changeset, _context ->
        Ash.Changeset.filter(changeset, expr(status == :pending))
      end)

      change(set_attribute(:status, :confirmed))
      change(set_attribute(:resolved_at, &DateTime.utc_now/0))
    end

    # 执行器失败回滚用（MEDIUM-2）：仅 confirmed 可回到 pending
    update :revert_to_pending do
      description("执行器失败后回滚到 pending（系统内部使用）")
      require_atomic?(false)

      change(fn changeset, _context ->
        Ash.Changeset.filter(changeset, expr(status == :confirmed))
      end)

      change(set_attribute(:status, :pending))
      change(set_attribute(:resolved_at, nil))
    end

    update :cancel do
      description("取消（仅本人、pending；原子条件更新）")
      require_atomic?(false)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          if cs.data.status == :pending do
            cs
          else
            invalid(cs, "Operation is not pending (status: #{cs.data.status})")
          end
        end)
      end)

      change(fn changeset, _context ->
        Ash.Changeset.filter(changeset, expr(status == :pending))
      end)

      change(set_attribute(:status, :cancelled))
      change(set_attribute(:resolved_at, &DateTime.utc_now/0))
    end
  end

  policies do
    policy action(:pend) do
      authorize_if(always())
    end

    policy action(:read) do
      authorize_if(expr(user_id == ^actor(:id)))
      authorize_if(actor_attribute_equals(:is_platform_admin, true))
    end

    policy action([:confirm, :cancel]) do
      authorize_if(expr(user_id == ^actor(:id)))
    end
  end

  defp invalid(changeset, message) do
    Ash.Changeset.add_error(
      changeset,
      Ash.Error.Changes.InvalidAttribute.exception(field: :status, message: message)
    )
  end
end
