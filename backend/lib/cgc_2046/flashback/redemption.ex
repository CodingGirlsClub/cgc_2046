defmodule Cgc2046.Flashback.Redemption do
  @moduledoc """
  奖品兑换申请（U11/R25）：当年比特币等未兑现奖品的兑换队列——人工处理
  （支付宝/微信/银行转账），**不在产品内做支付**。

  ## 提交面

  `flashbackRedeem` mutation（token 或登录账号，一人一行幂等）：当年中奖者
  从显影页的比特币提醒（R7 全场展示）自行前来提交兑换渠道信息。

  ## PII 边界（KTD3）

  `channel_note` 含收款账号等用户主动提交的转账信息：本资源无 GraphQL 查询
  面，读出口只有 admin 投影（`Flashback.AdminStats.redemptions/1` 白名单）；
  不进任何公开/校友投影。

  ## 状态（人工处理）

  `pending → contacted → settled | rejected`——流转由运营在 admin 面标记
  （`flashbackAdminUpdateRedemption`，PlatformAdmin）；fail-closed：非法
  转移由 admin_stats 的转移表拒绝。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  @statuses [:pending, :contacted, :settled, :rejected]

  attributes do
    uuid_primary_key(:id)

    attribute(:person_id, :uuid, allow_nil?: false, public?: true, writable?: true)

    # 兑换渠道信息（用户主动提交：支付宝/微信/银行转账方式与账号）。
    attribute(:channel_note, :string, allow_nil?: false, public?: true, writable?: true)

    # writable 供 admin_update_status 流转（合法转移表在 AdminStats——非 admin
    # 路径的守卫是 policy + 转移表双层）。
    attribute(:status, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      writable?: true,
      constraints: [one_of: @statuses]
    )

    # 运营处理备注（联系进度/打款凭证号等）。
    attribute(:handled_note, :string, public?: true, writable?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_person, [:person_id])
  end

  postgres do
    table("flashback_redemptions")
    repo(Cgc2046.Repo)
  end

  actions do
    defaults([:read])

    # flashbackRedeem 提交面（authorize?: false 路径；一人一行幂等由调用方
    # 以 unique_person 承接——已申请再交 = 更新渠道信息）。
    create :create do
      accept([:person_id, :channel_note])
    end

    update :update do
      require_atomic?(false)
      accept([:channel_note])
    end

    # admin 状态流转面（PlatformAdmin；非法转移在 AdminStats.update_status/3 拒绝）。
    update :admin_update_status do
      require_atomic?(false)
      accept([:status, :handled_note])
    end
  end

  admin do
    resource_group(:flashback)

    table_columns([:id, :person_id, :channel_note, :status, :handled_note, :inserted_at])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type(:create) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type(:update) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end
end
