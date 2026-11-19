defmodule Cgc2046.LlmGateway.PaymentOrder do
  @moduledoc """
  独立 LLM 算力收银台订单（Phase 3B，方案 B）。

  与 `Cgc2046.Payments.Order` 完全独立：本表只承载虚拟商品充值，不绑定
  Enrollment / Sponsorship，不参与报名占位、押金、退款状态机。报名支付主链路
  （payments_orders / PaymentSettlementWorker / Order）零改动。

  生命周期：`pending → paid`；`pending` 订单不占库存、不设超时释放，渠道
  迟到的成功支付仍按已付入账。金额单位为分（cents），算力入账单位为微积分
  （mc）：`1 cent = 10,000 mc`（1 CNY = 1,000,000 mc）。`credits_mc` 在创单时
  快照，后续改价/换价目表不追溯。

  - `:llm_subscription` / `:llm_credit_pack`：个人钱包，`workspace_id = nil`；
    订阅结算时另给 30 天有效期，加油包永久。
  - `:llm_workspace_pool_topup`：工作台算力池，`workspace_id` 必填；仅
    Owner/Admin（或 PlatformAdmin）可创单。

  `out_trade_no` 以 `LLM_` 前缀开头，现有支付回调入口按前缀分流到
  `LlmPaymentSettlementWorker`；`llm_credit_grants.payment_order_id` 指向本表。
  """

  use Ash.Resource,
    domain: Cgc2046.LlmGateway,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("llm_payment_orders")
    repo(Cgc2046.Repo)

    references do
      reference(:user, on_delete: :restrict)
      reference(:workspace, on_delete: :restrict)
    end

    check_constraints do
      check_constraint([:amount_cents], "llm_payment_orders_amount_positive",
        check: "amount_cents > 0",
        message: "amount_cents must be positive"
      )

      check_constraint([:credits_mc], "llm_payment_orders_credits_positive",
        check: "credits_mc > 0",
        message: "credits_mc must be positive"
      )

      check_constraint([:order_kind], "llm_payment_orders_kind_valid",
        check:
          "order_kind IN ('llm_subscription', 'llm_credit_pack', 'llm_workspace_pool_topup')",
        message: "unknown LLM payment order kind"
      )

      check_constraint([:order_kind, :workspace_id], "llm_payment_orders_anchor_valid",
        check: """
        (
          order_kind IN ('llm_subscription', 'llm_credit_pack')
          AND workspace_id IS NULL
        )
        OR (
          order_kind = 'llm_workspace_pool_topup'
          AND workspace_id IS NOT NULL
        )
        """,
        message: "LLM payment order kind and workspace anchor must match"
      )

      check_constraint([:provider], "llm_payment_orders_provider_valid",
        check:
          "provider IN ('wechat_jsapi', 'wechat_native', 'alipay_page', 'alipay_wap', 'alipay_qr')",
        message: "unknown LLM payment provider"
      )

      check_constraint([:status], "llm_payment_orders_status_valid",
        check: "status IN ('pending', 'paid', 'cancelled', 'expired')",
        message: "unknown LLM payment order status"
      )
    end
  end

  actions do
    defaults([:read])

    read :by_out_trade_no do
      argument(:out_trade_no, :string, allow_nil?: false)
      get?(true)
      filter(expr(out_trade_no == ^arg(:out_trade_no)))
    end

    read :by_idempotency_key do
      argument(:user_id, :uuid, allow_nil?: false)
      argument(:idempotency_key, :string, allow_nil?: false)
      get?(true)
      filter(expr(user_id == ^arg(:user_id) and idempotency_key == ^arg(:idempotency_key)))
    end

    create :create do
      accept([
        :user_id,
        :workspace_id,
        :order_kind,
        :provider,
        :out_trade_no,
        :amount_cents,
        :credits_mc,
        :status,
        :expires_at,
        :idempotency_key,
        :credential
      ])
    end

    update :mark_paid do
      accept([:transaction_id, :paid_at])
      require_atomic?(false)
      change(set_attribute(:status, :paid))
    end

    update :cancel do
      require_atomic?(false)
      change(set_attribute(:status, :cancelled))
    end

    update :expire do
      require_atomic?(false)
      change(set_attribute(:status, :expired))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action(:create) do
      authorize_if(actor_present())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:user_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "购买人（也是个人钱包入账用户）"
    )

    attribute(:workspace_id, :uuid,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "工作台池充值目标；个人订单为空"
    )

    attribute(:order_kind, :atom,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [
        one_of: [:llm_subscription, :llm_credit_pack, :llm_workspace_pool_topup]
      ],
      description: "llm_subscription | llm_credit_pack | llm_workspace_pool_topup"
    )

    attribute(:provider, :atom,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [
        one_of: [:wechat_jsapi, :wechat_native, :alipay_page, :alipay_wap, :alipay_qr]
      ]
    )

    attribute(:out_trade_no, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "渠道商户单号；固定 LLM_ 前缀供回调分流"
    )

    attribute(:amount_cents, :integer,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [min: 1],
      description: "实付金额（分）"
    )

    attribute(:credits_mc, :integer,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [min: 1],
      description: "创单时快照的入账算力（1 cent = 10,000 mc）"
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      writable?: true,
      constraints: [one_of: [:pending, :paid, :cancelled, :expired]]
    )

    attribute(:expires_at, :utc_datetime_usec,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "展示用支付截止时间；本阶段不设抢占资源，不挂过期 worker"
    )

    attribute(:paid_at, :utc_datetime_usec, public?: true, writable?: true)

    attribute(:transaction_id, :string, public?: true, writable?: true)

    attribute(:credential, :map,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "渠道创建返回的前端凭据（二维码/跳转参数）；幂等重放原样返回"
    )

    attribute(:idempotency_key, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "同一购买人重复创单的幂等键"
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

    belongs_to(:workspace, Cgc2046.Accounts.Workspace,
      allow_nil?: true,
      public?: true,
      attribute_writable?: false
    )
  end

  identities do
    identity(:unique_out_trade_no, [:out_trade_no])
    identity(:unique_user_idempotency, [:user_id, :idempotency_key])
  end
end
