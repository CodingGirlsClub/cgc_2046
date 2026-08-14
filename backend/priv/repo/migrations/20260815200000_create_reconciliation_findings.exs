defmodule Cgc2046.Repo.Migrations.CreateReconciliationFindings do
  use Ecto.Migration

  @moduledoc """
  E-10 #125 对账扫描：平台级孤儿报告表（Reconciliation.Finding 资源）。

  - 唯一索引 (rule, entity_type, entity_id)：刷新语义的判重键——同规则同实体至多
    一行，命中 upsert 保 first_seen_at。
  - (rule, last_seen_at)：按规则扫描清理 + 对账页按规则倒序列表。
  - workspace_id 可空（全局实体无租户），单独索引供对账页过滤。
  """

  def up do
    create table(:reconciliation_findings, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :rule, :text, null: false
      add :entity_type, :text, null: false
      add :entity_id, :string, null: false
      add :workspace_id, :uuid
      add :detail, :map, null: false, default: fragment("'{}'::jsonb")
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:reconciliation_findings, [:rule, :entity_type, :entity_id],
             name: "reconciliation_findings_unique_finding_index"
           )

    create index(:reconciliation_findings, [:rule, :last_seen_at])
    create index(:reconciliation_findings, [:workspace_id])
  end

  def down do
    drop table(:reconciliation_findings)
  end
end
