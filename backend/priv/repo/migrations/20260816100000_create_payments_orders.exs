defmodule Cgc2046.Repo.Migrations.CreatePaymentsOrders do
  @moduledoc """
  支付闭环 U1：payments_orders（座位保留型限时订单）+ payments_webhook_events
  （渠道回调幂等去重，R21）。

  - 部分唯一索引 = 报名/赞助同款「非终态不重复」兜底（R11）：同一 enrollment
    至多一笔 pending/paid/refunding/refund_failed 订单；cancelled/expired/
    refunded 终态放行新单。索引同时守卫状态迁移路径——expired 单进入
    refunding 的 CAS UPDATE 同样受该索引约束。
  - 状态迁移原子性由 Order 资源内的条件 UPDATE 承担（报名 claim_pending
    同款），无需额外约束。
  """

  use Ecto.Migration

  def up do
    create table(:payments_orders, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :workspace_id,
          references(:workspaces, type: :uuid, on_delete: :delete_all),
          null: false

      add :enrollment_id,
          references(:enrollments, type: :uuid, on_delete: :delete_all),
          null: false

      add :provider, :text, null: false
      add :out_trade_no, :text, null: false
      add :transaction_id, :text
      add :amount_cents, :bigint, null: false
      add :tier_snapshot, :map, null: false, default: %{}
      add :status, :text, null: false, default: "pending"
      add :expire_at, :utc_datetime, null: false
      add :refunded_at, :utc_datetime
      add :cancel_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:payments_orders, [:out_trade_no],
             name: "payments_orders_unique_out_trade_no_index"
           )

    create unique_index(:payments_orders, [:enrollment_id],
             name: "payments_orders_unique_active_order_index",
             where: "status IN ('pending', 'paid', 'refunding', 'refund_failed')"
           )

    create index(:payments_orders, [:workspace_id, :status])
    create index(:payments_orders, [:status, :expire_at])

    create table(:payments_webhook_events, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :provider, :text, null: false
      add :event_id, :text, null: false
      add :payload, :map, null: false, default: %{}
      add :status, :text, null: false, default: "received"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:payments_webhook_events, [:provider, :event_id],
             name: "payments_webhook_events_unique_provider_event_index"
           )
  end

  def down do
    drop(table(:payments_webhook_events))
    drop(table(:payments_orders))
  end
end
