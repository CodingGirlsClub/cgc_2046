defmodule Cgc2046.Repo.Migrations.AddPricingToOfferings do
  @moduledoc """
  缴费闭环 U2：Event/Course 可选收费配置（R1/R4）。

  - `pricing_enabled` 默认 false：免费是默认路径，字段缺失语义 = 免费；
  - `price_tiers` jsonb 默认 '[]'：嵌入式档位（PriceTier 形状）。
  """

  use Ecto.Migration

  def up do
    alter table(:events) do
      add :pricing_enabled, :boolean, null: false, default: false
      add :price_tiers, :map, null: false, default: fragment("'[]'::jsonb")
    end

    alter table(:courses) do
      add :pricing_enabled, :boolean, null: false, default: false
      add :price_tiers, :map, null: false, default: fragment("'[]'::jsonb")
    end
  end

  def down do
    alter table(:events) do
      remove :pricing_enabled
      remove :price_tiers
    end

    alter table(:courses) do
      remove :pricing_enabled
      remove :price_tiers
    end
  end
end
