defmodule Cgc2046.Payments.Order do
  @moduledoc """
  支付订单：座位保留型限时订单（默认 2 小时），微信/支付宝收款，在线全额
  退款（退款 = 取消报名，ADR-0007）。

  状态机（全部迁移经 DB 级 CAS：before_action 内条件 UPDATE + num_rows 守卫，
  非法迁移 → :already_processed 域错误，报名 claim_pending 同款纪律）：

      pending ──mark_paid──▶ paid ──start_refund──▶ refunding ──refund_succeeded──▶ refunded
        │                      │                        │  ▲
        ├──cancel──▶ cancelled │                        │  └──refund_failed──▶ refund_failed
        └──expire──▶ expired ──┘                        │         ▲（refunding → refund_failed）
                               └──start_refund（迟到支付自动退款）└──retry_refund──▶ refunding

  并发不变量由数据库承担（报名/赞助同款纪律）：
  - R11「同一 enrollment 至多一笔非终态订单」：payments_orders 上的部分唯一索引
    （enrollment_id WHERE status IN ('pending','paid','refunding','refund_failed')）。
    索引同时守卫 CAS 迁移路径：expired 单进入 refunding 时若已存在新非终态单，
    条件 UPDATE 触发唯一冲突 → 迁移失败回滚；
  - 状态迁移原子性：每条迁移一条 `UPDATE ... WHERE id = $ AND status IN (源状态)`
    条件 UPDATE，num_rows=0 即非法迁移。

  U1 骨架：全部动作均为内部路径（worker/域服务 authorize?: false 调用），
  GraphQL/管理面尚未暴露；policy 占位为 actor 在场（拒匿名），面向用户的正式
  授权（学员本人 / Owner/Admin / 平台管理员）随 U5/U9 暴露时细化。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Payments

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false
    )

    attribute(:enrollment_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true
    )

    attribute(:provider, :atom,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [one_of: [:wechat_jsapi, :wechat_native, :alipay_page, :alipay_wap]]
    )

    attribute(:out_trade_no, :string,
      allow_nil?: false,
      public?: true,
      writable?: true
    )

    attribute(:transaction_id, :string, public?: true, writable?: false)

    attribute(:amount_cents, :integer,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [min: 1]
    )

    attribute(:tier_snapshot, :map,
      allow_nil?: false,
      default: %{},
      public?: true,
      writable?: true
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      writable?: false,
      constraints: [
        one_of: [:pending, :paid, :refunding, :refunded, :refund_failed, :cancelled, :expired]
      ]
    )

    attribute(:expire_at, :utc_datetime, allow_nil?: false, public?: true, writable?: true)
    attribute(:refunded_at, :utc_datetime, public?: true, writable?: false)
    attribute(:cancel_reason, :string, public?: true, writable?: false)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)
    global?(true)
  end

  relationships do
    belongs_to(:workspace, Cgc2046.Accounts.Workspace, define_attribute?: false)
    belongs_to(:enrollment, Cgc2046.Events.Enrollment, define_attribute?: false)
  end

  identities do
    identity(:unique_out_trade_no, [:out_trade_no])

    identity :unique_active_order, [:enrollment_id] do
      where(expr(status in [:pending, :paid, :refunding, :refund_failed]))
    end
  end

  actions do
    defaults([:read])

    create :create do
      description("创建 pending 订单；U1 骨架从 enrollment 派生租户，定价/占位随 U2/U3 落地")

      accept([
        :enrollment_id,
        :provider,
        :out_trade_no,
        :amount_cents,
        :tier_snapshot,
        :expire_at
      ])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_create/1)
      end)
    end

    update :mark_paid do
      description("支付成功：pending → paid（回写渠道交易号）")
      require_atomic?(false)
      accept([])
      argument(:transaction_id, :string, allow_nil?: false)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_mark_paid/1)
      end)
    end

    update :cancel do
      description("未支付取消：pending → cancelled（用户取消/换渠道/批量作废共用）")
      require_atomic?(false)
      accept([])
      argument(:cancel_reason, :string, allow_nil?: true)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_cancel/1)
      end)
    end

    update :expire do
      description("内部扫描把过期 pending 单转 expired（expire_at 过点由调用方判定）")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_expire/1)
      end)
    end

    update :start_refund do
      description("发起退款：paid/expired → refunding（expired 为迟到支付自动退款路径）")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_start_refund/1)
      end)
    end

    update :refund_succeeded do
      description("退款成功：refunding → refunded，落 refunded_at")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_refund_succeeded/1)
      end)
    end

    update :mark_refund_failed do
      description("退款失败：refunding → refund_failed（可经 retry_refund 重试）")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_mark_refund_failed/1)
      end)
    end

    update :retry_refund do
      description("重试退款：refund_failed → refunding")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_retry_refund/1)
      end)
    end
  end

  postgres do
    table("payments_orders")
    repo(Cgc2046.Repo)

    identity_wheres_to_sql(
      unique_active_order: "status IN ('pending', 'paid', 'refunding', 'refund_failed')"
    )
  end

  policies do
    # U1 骨架占位：全部动作走内部路径（worker/域服务 authorize?: false 调用），
    # GraphQL/Admin 尚未暴露。占位策略要求 actor 在场（拒匿名）；面向用户的
    # 正式授权（学员本人 / Owner/Admin / 平台管理员）随 U5/U9 暴露时细化。
    policy always() do
      authorize_if(actor_present())
    end
  end

  # ── 建单（U1：从 enrollment 派生租户；定价/占位语义随 U2/U3 落地）────────

  defp prepare_create(changeset) do
    enrollment_id = Ash.Changeset.get_attribute(changeset, :enrollment_id)

    with {:ok, workspace_id} <- enrollment_workspace(enrollment_id),
         {:ok, tenant} <- resolve_tenant(changeset.tenant, workspace_id) do
      Ash.Changeset.force_change_attribute(changeset, :workspace_id, tenant)
    else
      {:error, reason} -> add_domain_error(changeset, reason)
    end
  end

  defp enrollment_workspace(id) when is_binary(id) do
    case Cgc2046.Repo.query("SELECT workspace_id FROM enrollments WHERE id = $1", [
           Cgc2046.Repo.uuid!(id)
         ]) do
      {:ok, %{rows: [[workspace_id]]}} -> {:ok, Ecto.UUID.load!(workspace_id)}
      {:ok, %{rows: []}} -> {:error, :enrollment_not_found}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  defp enrollment_workspace(_id), do: {:error, :enrollment_required}

  # GraphQL 入口不注入 tenant（nil 时从 enrollment 派生）；显式传错 tenant 仍拒绝
  # （防跨 workspace 越权，报名同款）
  defp resolve_tenant(nil, workspace_id), do: {:ok, workspace_id}
  defp resolve_tenant(tenant, tenant), do: {:ok, tenant}
  defp resolve_tenant(_, _), do: {:error, :target_tenant_mismatch}

  # ── 状态迁移（DB 级 CAS：条件 UPDATE + num_rows 守卫）────────────────────

  defp prepare_mark_paid(changeset) do
    transaction_id = Ash.Changeset.get_argument(changeset, :transaction_id)

    case claim(changeset, [:pending], "status = 'paid', transaction_id = $1", [transaction_id]) do
      {:ok, changeset} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :paid)
        |> Ash.Changeset.force_change_attribute(:transaction_id, transaction_id)

      {:error, changeset} ->
        changeset
    end
  end

  defp prepare_cancel(changeset) do
    cancel_reason = Ash.Changeset.get_argument(changeset, :cancel_reason)

    case claim(changeset, [:pending], "status = 'cancelled', cancel_reason = $1", [
           cancel_reason
         ]) do
      {:ok, changeset} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :cancelled)
        |> Ash.Changeset.force_change_attribute(:cancel_reason, cancel_reason)

      {:error, changeset} ->
        changeset
    end
  end

  defp prepare_expire(changeset) do
    case claim(changeset, [:pending], "status = 'expired'") do
      {:ok, changeset} -> Ash.Changeset.force_change_attribute(changeset, :status, :expired)
      {:error, changeset} -> changeset
    end
  end

  defp prepare_start_refund(changeset) do
    case claim(changeset, [:paid, :expired], "status = 'refunding'") do
      {:ok, changeset} -> Ash.Changeset.force_change_attribute(changeset, :status, :refunding)
      {:error, changeset} -> changeset
    end
  end

  defp prepare_refund_succeeded(changeset) do
    now = DateTime.utc_now()

    case claim(changeset, [:refunding], "status = 'refunded', refunded_at = $1", [now]) do
      {:ok, changeset} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :refunded)
        |> Ash.Changeset.force_change_attribute(:refunded_at, now)

      {:error, changeset} ->
        changeset
    end
  end

  defp prepare_mark_refund_failed(changeset) do
    case claim(changeset, [:refunding], "status = 'refund_failed'") do
      {:ok, changeset} -> Ash.Changeset.force_change_attribute(changeset, :status, :refund_failed)
      {:error, changeset} -> changeset
    end
  end

  defp prepare_retry_refund(changeset) do
    case claim(changeset, [:refund_failed], "status = 'refunding'") do
      {:ok, changeset} -> Ash.Changeset.force_change_attribute(changeset, :status, :refunding)
      {:error, changeset} -> changeset
    end
  end

  # 条件 UPDATE CAS：WHERE 带 id + 源状态守卫。命中（num_rows=1）→ 返回
  # {:ok, changeset}，调用方 force_change 附加字段；未命中 → :already_processed；
  # SQL 失败（含 R11 唯一冲突等 DB 约束拒绝）→ :database。set_sql 内占位符
  # 从 $1 起连续编号，id 固定为最后一个参数。
  defp claim(changeset, from_statuses, set_sql, params \\ []) do
    sources = Enum.map_join(from_statuses, ", ", &"'#{&1}'")

    sql = """
    UPDATE payments_orders
    SET #{set_sql}, updated_at = NOW()
    WHERE id = $#{length(params) + 1} AND status IN (#{sources})
    """

    case Cgc2046.Repo.query(sql, params ++ [Cgc2046.Repo.uuid!(changeset.data.id)]) do
      {:ok, %{num_rows: 1}} -> {:ok, changeset}
      {:ok, %{num_rows: 0}} -> {:error, add_domain_error(changeset, :already_processed)}
      {:error, reason} -> {:error, add_domain_error(changeset, {:database, reason})}
    end
  end

  # ── 错误文案 ───────────────────────────────────────────────────────────────

  defp add_domain_error(changeset, reason) do
    Ash.Changeset.add_error(changeset,
      field: :status,
      message: domain_error_message(reason)
    )
  end

  defp domain_error_message(:enrollment_required), do: "enrollment_id is required"
  defp domain_error_message(:enrollment_not_found), do: "enrollment does not exist"

  defp domain_error_message(:target_tenant_mismatch),
    do: "enrollment does not belong to tenant"

  defp domain_error_message(:already_processed), do: "order has already been processed"
  defp domain_error_message({:database, _reason}), do: "database operation failed"
  defp domain_error_message(reason), do: inspect(reason)
end
