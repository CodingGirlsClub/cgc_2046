defmodule Cgc2046.LlmGateway.WorkspacePoolEntry do
  @moduledoc """
  工作台算力池追加账本行（Plan 010）。

  与 `workspaces.credit_pool_mc` 保持守恒不变量：
  `workspaces.credit_pool_mc == SUM(delta_mc)`（由 `:llm_workspace_pool_mismatch` 对账守卫）。
  `payment_order_id` 与 `workspace_batch_id` 各自具备部分唯一索引，为订单结算入池与
  批量派发扣池提供数据库级幂等保障。

  资源只暴露读面；写路径全部收敛在 `Cgc2046.LlmGateway.Ledger` 的原子事务 SQL。
  """

  use Ash.Resource,
    domain: Cgc2046.LlmGateway,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("llm_workspace_pool_entries")
    repo(Cgc2046.Repo)

    references do
      reference(:workspace, on_delete: :restrict)
      reference(:payment_order, on_delete: :restrict)
      reference(:workspace_batch, on_delete: :restrict)
      reference(:actor_user, on_delete: :restrict)
    end
  end

  actions do
    defaults([:read])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)

      authorize_if({Cgc2046.Accounts.Policies.ActorIsWorkspaceMemberVia, path: [:workspace]})
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:entry_type, :atom,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [one_of: [:order_topup, :admin_topup, :batch_grant_debit, :migration_baseline]]
    )

    attribute(:delta_mc, :integer,
      allow_nil?: false,
      public?: true,
      writable?: false
    )

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to(:workspace, Cgc2046.Accounts.Workspace,
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

    belongs_to(:actor_user, Cgc2046.Accounts.User,
      allow_nil?: true,
      public?: true,
      attribute_writable?: false
    )
  end
end
