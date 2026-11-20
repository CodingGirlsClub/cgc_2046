defmodule Cgc2046.LlmGateway.CreditGrant do
  @moduledoc """
  用户钱包内的单个额度批次。消费顺序固定为
  `expires_at ASC NULLS LAST, inserted_at ASC`：会到期的订阅额度先于永久
  算力包被消耗。

  批次状态由结算/到期 Worker 维护：`active` → `exhausted`（余额耗尽）或
  `expired`（到期未用额度由 `CreditExpiryWorker` 归零）。
  """

  use Ash.Resource,
    domain: Cgc2046.LlmGateway,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("llm_credit_grants")
    repo(Cgc2046.Repo)

    references do
      reference(:wallet, on_delete: :restrict)
      reference(:user, on_delete: :restrict)
      reference(:payment_order, on_delete: :restrict)
      reference(:workspace_batch, on_delete: :restrict)
      reference(:sponsor_workspace, on_delete: :restrict)
      reference(:granted_by_user, on_delete: :restrict)
    end
  end

  actions do
    defaults([:read])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
      authorize_if(expr(user_id == ^actor(:id)))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:source_type, :atom,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [one_of: [:subscription, :pack, :workspace_grant, :admin_gift]]
    )

    attribute(:initial_mc, :integer,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [min: 1]
    )

    attribute(:remaining_mc, :integer,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [min: 0]
    )

    attribute(:expires_at, :utc_datetime_usec,
      allow_nil?: true,
      public?: true,
      writable?: false
    )

    # 到期时被 CreditExpiryWorker 清零的未用额度累计；与 remaining_mc 一起让
    # 「已消耗 = initial - remaining - expired」在到期后仍可还原（派发批次使用率回看）。
    attribute(:expired_mc, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      writable?: false,
      constraints: [min: 0]
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :active,
      public?: true,
      writable?: false,
      constraints: [one_of: [:active, :exhausted, :expired]]
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:wallet, Cgc2046.LlmGateway.Wallet,
      allow_nil?: false,
      public?: true,
      attribute_writable?: false
    )

    belongs_to(:user, Cgc2046.Accounts.User,
      allow_nil?: false,
      public?: true,
      attribute_writable?: false
    )

    belongs_to(:payment_order, Cgc2046.LlmGateway.PaymentOrder,
      allow_nil?: true,
      public?: true,
      attribute_writable?: false
    )

    belongs_to(:workspace_batch, Cgc2046.LlmGateway.WorkspaceGrantBatch,
      allow_nil?: true,
      public?: true,
      attribute_writable?: false
    )

    belongs_to(:sponsor_workspace, Cgc2046.Accounts.Workspace,
      allow_nil?: true,
      public?: true,
      attribute_writable?: false
    )

    belongs_to(:granted_by_user, Cgc2046.Accounts.User,
      allow_nil?: true,
      public?: true,
      attribute_writable?: false
    )
  end
end
