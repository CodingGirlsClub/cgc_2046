defmodule Cgc2046.LlmGateway.UsageLog do
  @moduledoc """
  每次 LLM 请求的不可变账本行：同时记录向用户收取的微积分
  （`charged_mc`）与上游实际 API 成本（`upstream_cost_mc`），
  供毛利核算、渠道对比与异常账单审计。

  `billing_mode` 区分精确结算、断流估算与上游错误豁免三种口径。
  """

  use Ash.Resource,
    domain: Cgc2046.LlmGateway,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("llm_usage_logs")
    repo(Cgc2046.Repo)

    references do
      reference(:wallet, on_delete: :restrict)
      reference(:user, on_delete: :restrict)
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

    attribute(:session_id, :string, public?: true, writable?: false)
    attribute(:logical_model, :string, allow_nil?: false, public?: true, writable?: false)
    attribute(:upstream_channel, :string, allow_nil?: false, public?: true, writable?: false)
    attribute(:upstream_model, :string, allow_nil?: false, public?: true, writable?: false)

    attribute(:billing_mode, :atom,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [one_of: [:exact, :estimated_abort, :waived_upstream_error]]
    )

    attribute(:prompt_cache_hit_tokens, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      writable?: false
    )

    attribute(:prompt_cache_miss_tokens, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      writable?: false
    )

    attribute(:completion_tokens, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      writable?: false
    )

    attribute(:reasoning_tokens, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      writable?: false
    )

    attribute(:charged_mc, :integer,
      allow_nil?: false,
      public?: true,
      writable?: false
    )

    attribute(:upstream_cost_mc, :integer,
      allow_nil?: false,
      public?: true,
      writable?: false
    )

    attribute(:ttfb_ms, :integer, public?: true, writable?: false)
    attribute(:duration_ms, :integer, public?: true, writable?: false)

    create_timestamp(:inserted_at)
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
  end
end
