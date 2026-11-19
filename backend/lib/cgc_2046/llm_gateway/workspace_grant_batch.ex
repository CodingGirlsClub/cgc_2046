defmodule Cgc2046.LlmGateway.WorkspaceGrantBatch do
  @moduledoc """
  工作台 Owner/Admin 从工作台算力池向当前全部成员批量派发额度的审计与
  幂等记录。`(workspace_id, idempotency_key)` 唯一；重复提交返回原批次而不
  二次扣池。

  派发的额度进入成员个人钱包（`source_type: :workspace_grant`），落账后不受
  工作台限制，可跨空间消费。
  """

  use Ash.Resource,
    domain: Cgc2046.LlmGateway,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("llm_workspace_grant_batches")
    repo(Cgc2046.Repo)

    references do
      reference(:workspace, on_delete: :restrict)
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

    attribute(:per_member_mc, :integer,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [min: 1]
    )

    attribute(:member_count, :integer,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [min: 1]
    )

    attribute(:total_granted_mc, :integer,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [min: 1]
    )

    attribute(:expires_at, :utc_datetime_usec,
      allow_nil?: true,
      public?: true,
      writable?: false
    )

    attribute(:idempotency_key, :string,
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

    belongs_to(:actor_user, Cgc2046.Accounts.User,
      allow_nil?: false,
      public?: true,
      attribute_writable?: false
    )

    has_many(:credit_grants, Cgc2046.LlmGateway.CreditGrant,
      destination_attribute: :workspace_batch_id
    )
  end

  identities do
    identity(:unique_workspace_idempotency, [:workspace_id, :idempotency_key])
  end
end
