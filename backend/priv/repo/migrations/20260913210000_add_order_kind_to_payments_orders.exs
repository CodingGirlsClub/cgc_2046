defmodule Cgc2046.Repo.Migrations.AddOrderKindToPaymentsOrders do
  use Ecto.Migration

  def change do
    alter table(:payments_orders) do
      add :order_kind, :string, null: false, default: "enrollment"
    end

    create index(:payments_orders, [:enrollment_id, :order_kind, :status])
  end
end
