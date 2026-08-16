defmodule Cgc2046.Payments.WebhookEvent do
  @moduledoc """
  渠道回调原始事件（R21 幂等去重）。

  内部资源：不暴露 GraphQL/Admin。回调处理器先落库——(provider, event_id)
  唯一索引挡渠道重复投递（微信/支付宝均会重试回调），重复插入冲突 = 已收到，
  调用方按成功回执处理；消费状态（received → processed）随回调处理单元落地。

  policy 占位要求 actor 在场（拒匿名）：worker 回调处理器以 authorize?: false
  调用，本资源永不面向用户。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Payments

  attributes do
    uuid_primary_key(:id)

    attribute(:provider, :atom,
      allow_nil?: false,
      constraints: [one_of: [:wechat, :alipay]]
    )

    attribute(:event_id, :string, allow_nil?: false)

    attribute(:payload, :map,
      allow_nil?: false,
      default: %{}
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :received,
      writable?: false,
      constraints: [one_of: [:received, :processed]]
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_provider_event, [:provider, :event_id])
  end

  actions do
    defaults([:read])

    create :create do
      description("落库一条渠道回调；重复 (provider, event_id) 由唯一索引拒绝")
      accept([:provider, :event_id, :payload])
    end

    # 落账 worker 消费后标记（received → processed）；幂等重放经唯一索引去重，
    # 不依赖 status 判定。
    update :mark_processed do
      description("落账 worker 消费完成标记")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :processed)
      end)
    end
  end

  postgres do
    table("payments_webhook_events")
    repo(Cgc2046.Repo)
  end

  policies do
    # 内部资源：worker 回调处理器以 authorize?: false 调用；占位要求 actor
    # 在场拒匿名，永不暴露 GraphQL/Admin。
    policy always() do
      authorize_if(actor_present())
    end
  end
end
