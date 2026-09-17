defmodule Cgc2046.Flashback.Outreach do
  @moduledoc """
  外发记录（KTD6/R23）：一次批量触达中某人的某通道发送行。

  - `unique_send`（person + channel + batch）= DB 级幂等承载：重跑批次零新增
    （Oban unique 之外的第二道闸，断点续发以 batch 分组）；
  - 记录只留发送/退订状态——**不引入开信像素**（KTD6：四率之外的行为事件
    一律走 FlashbackTouch；`opened_at` 不建）；
  - 个人字段（手机/邮箱）不入本表：外发 worker 经 person_id 回查 Person，
    U10 删除时对 person 行匿名化即自动切断（U8 落地）。

  状态推进（sent/failed/unsubscribed 回写）与退订抑制属 U8：届时以显式
  action（`set_attribute`）落地，本资源 U1 只建入队行。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  @channels [:email, :sms]
  @statuses [:queued, :sent, :failed]

  attributes do
    uuid_primary_key(:id)

    attribute(:person_id, :uuid, allow_nil?: false, public?: true, writable?: true)

    attribute(:channel, :atom,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [one_of: @channels]
    )

    # 模板标识（邮件模板模块 / SendCloud 短信模板 env 键）。
    attribute(:template, :string, allow_nil?: false, public?: true, writable?: true)
    # 批次号（outreach worker 入队时的 Oban args 携带；幂等分组键）。
    attribute(:batch, :string, allow_nil?: false, public?: true, writable?: true)

    attribute(:status, :atom,
      allow_nil?: false,
      default: :queued,
      public?: true,
      writable?: false,
      constraints: [one_of: @statuses]
    )

    attribute(:sent_at, :utc_datetime_usec, public?: true, writable?: false)
    attribute(:unsubscribed_at, :utc_datetime_usec, public?: true, writable?: false)
    # 失败原因（硬退信等）；不含个人字段。
    attribute(:detail, :string, public?: true, writable?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:person, Cgc2046.Flashback.Person,
      source_attribute: :person_id,
      destination_attribute: :id,
      define_attribute?: false
    )
  end

  identities do
    identity(:unique_send, [:person_id, :channel, :batch])
  end

  postgres do
    table("flashback_outreaches")
    repo(Cgc2046.Repo)
  end

  actions do
    defaults([:read])

    # U8 outreach worker 入队即建行（authorize?: false 路径）。
    create :create do
      accept([:person_id, :channel, :template, :batch])
    end
  end

  admin do
    resource_group(:flashback)

    table_columns([:id, :person_id, :channel, :template, :batch, :status, :sent_at])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type(:create) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end
end
