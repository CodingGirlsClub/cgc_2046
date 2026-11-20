defmodule Cgc2046.LlmGateway.Wallet do
  @moduledoc """
  用户级算力钱包。个人订阅、算力包、工作台批量派发的额度统一汇聚在这里，
  可跨任意工作台或本地桌面会话消费。

  `cached_balance_mc` 是全部 active 批次 `remaining_mc` 之和的缓存（微积分，
  microcredit）；`held_mc` 是流式请求预授权冻结额。两者由
  `Cgc2046.LlmGateway.Ledger` 在行锁/条件 UPDATE 下维护，资源本身只读。
  """

  use Ash.Resource,
    domain: Cgc2046.LlmGateway,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("llm_wallets")
    repo(Cgc2046.Repo)

    references do
      reference(:user, on_delete: :restrict)
    end
  end

  actions do
    defaults([:read])

    read :by_user do
      argument(:user_id, :uuid, allow_nil?: false)
      get?(true)
      filter(expr(user_id == ^arg(:user_id)))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
      authorize_if(expr(user_id == ^actor(:id)))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:cached_balance_mc, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      writable?: false,
      constraints: [min: 0]
    )

    attribute(:held_mc, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      writable?: false,
      constraints: [min: 0]
    )

    attribute(:max_concurrent_streams, :integer,
      allow_nil?: false,
      default: 3,
      public?: true,
      writable?: false,
      constraints: [min: 1]
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :active,
      public?: true,
      writable?: false,
      constraints: [one_of: [:active, :frozen]]
    )

    attribute(:frozen_reason, :string,
      allow_nil?: true,
      public?: true,
      writable?: false
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:user, Cgc2046.Accounts.User,
      allow_nil?: false,
      public?: true,
      attribute_writable?: false
    )

    has_many(:credit_grants, Cgc2046.LlmGateway.CreditGrant, destination_attribute: :wallet_id)

    has_many(:usage_logs, Cgc2046.LlmGateway.UsageLog, destination_attribute: :wallet_id)
  end

  identities do
    identity(:unique_user_wallet, [:user_id])
  end
end
