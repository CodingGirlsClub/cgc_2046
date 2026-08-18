defmodule Cgc2046.Repo.Migrations.CreateMiniprogramShareSchemes do
  @moduledoc """
  plan 011 P1：微信 URL Scheme 分享链接缓存表（spike §6 D2-A 复用拍板）。

  `(target_kind, target_id, platform)` 唯一——同一目标/平台只留一份 scheme，
  未过期复用、过期重生成覆盖（upsert）。无数据回填（lazy 生成）。
  """

  use Ecto.Migration

  def up do
    create table(:miniprogram_share_schemes, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :target_kind, :text, null: false
      add :target_id, :uuid, null: false
      add :platform, :text, null: false
      add :openlink, :text, null: false
      add :expires_at, :utc_datetime, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:miniprogram_share_schemes, [:target_kind, :target_id, :platform],
             name: "miniprogram_share_schemes_unique_target_platform_index"
           )
  end

  def down do
    drop table(:miniprogram_share_schemes)
  end
end
