defmodule Cgc2046.Events.SponsorshipDelivery do
  @moduledoc """
  履约账本（E-3 #48，D5 拍板）：Sponsorship 激活（A3）同事务从 tier.benefits
  物化的交付行。

  - 每行 = 一项权益：benefit（权益名）、due_date（可空，v1 无时限约定）、
    fulfilled_at + proof_note（后台逐项核销 proof-of-performance）、
    exclusive（独占位标记，随档位复制）。
  - 欠交付 = fulfilled_at 为空的未核销行自然可见（makegood 二期，不做）。
  - 核销幂等：条件 UPDATE 状态守卫（fulfilled_at IS NULL），重复核销拒绝。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Api

  alias Cgc2046.Repo

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（物化时从 Sponsorship 复制，租户）"
    )

    attribute(:sponsorship_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false
    )

    attribute(:benefit, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "权益项名（物化自 tier.benefits）"
    )

    attribute(:due_date, :utc_datetime, public?: true, writable?: true)
    attribute(:fulfilled_at, :utc_datetime, public?: true, writable?: false)
    attribute(:proof_note, :string, public?: true, writable?: false)

    attribute(:exclusive, :boolean,
      allow_nil?: false,
      default: false,
      public?: true,
      writable?: true,
      description: "独占位标记（随档位复制）"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)
    global?(true)
  end

  relationships do
    belongs_to(:sponsorship, Cgc2046.Events.Sponsorship, define_attribute?: false)
  end

  actions do
    defaults([:read])

    update :fulfill do
      description("后台核销交付行（fulfilled_at + proof_note；Owner/Admin）")
      require_atomic?(false)
      accept([])
      argument(:proof_note, :string, allow_nil?: false)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_fulfill/1)
      end)
    end
  end

  postgres do
    table("sponsorship_deliveries")
    repo(Cgc2046.Repo)
  end

  policies do
    # 核销：目标工作台 Owner/Admin（平台 Admin 备案二期，不参与）
    policy action(:fulfill) do
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
    end

    # 读取：唯一暴露面是 Sponsorship.deliveries 关系字段（父行已授权）；
    # 关系加载 query 无 tenant，经 SponsorshipDeliveryReadable 把父行授权
    # 翻译到交付行（sponsor 本人 / 目标工作台 Owner/Admin）。
    policy action_type(:read) do
      authorize_if(Cgc2046.Policies.SponsorshipDeliveryReadable)
    end
  end

  graphql do
    type(:sponsorship_delivery)

    mutations do
      update(:fulfill_delivery, :fulfill)
    end
  end

  defp prepare_fulfill(changeset) do
    now = DateTime.utc_now()
    proof_note = Ash.Changeset.get_argument(changeset, :proof_note)

    sql = """
    UPDATE sponsorship_deliveries
    SET fulfilled_at = $1, proof_note = $2, updated_at = NOW()
    WHERE id = $3 AND fulfilled_at IS NULL
    """

    case Repo.query(sql, [now, proof_note, uuid!(changeset.data.id)]) do
      {:ok, %{num_rows: 1}} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:fulfilled_at, now)
        |> Ash.Changeset.force_change_attribute(:proof_note, proof_note)

      {:ok, %{num_rows: 0}} ->
        add_domain_error(changeset, :already_fulfilled)

      {:error, reason} ->
        add_domain_error(changeset, {:database, reason})
    end
  end

  defp add_domain_error(changeset, reason) do
    Ash.Changeset.add_error(changeset,
      field: :fulfilled_at,
      message: domain_error_message(reason)
    )
  end

  defp domain_error_message(:already_fulfilled), do: "delivery has already been fulfilled"
  defp domain_error_message({:database, _reason}), do: "database operation failed"
  defp domain_error_message(reason), do: inspect(reason)

  defp uuid!(value), do: Ecto.UUID.dump!(value)

  admin do
    resource_group(:events)
    table_columns([:id, :sponsorship_id, :benefit, :due_date, :fulfilled_at, :exclusive])
  end
end
