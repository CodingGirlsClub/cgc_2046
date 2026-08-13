defmodule Cgc2046.Repo.Migrations.CreateSponsorships do
  use Ecto.Migration

  @moduledoc """
  E-3 #48 赞助 workflow：Sponsorship/SponsorshipDelivery 表 + Event/Workspace
  赞助配置字段（sponsorship_enabled 已在 workspaces 落地，events 补齐）。

  - 部分唯一索引 = 报名同款「未终态不重复」兜底：(level, target, sponsor) 在
    pending/active 窗口内唯一；rejected/expired/ended 终态放行重提。
  - 独占权益位由激活条件 UPDATE 的 NOT EXISTS 守卫（无索引需求，见 sponsorship.ex）。
  """

  def up do
    alter table(:events) do
      add :sponsorship_enabled, :boolean, null: false, default: true
      add :sponsorship_tiers, :map, null: false, default: fragment("'[]'::jsonb")
      add :sponsorship_deadline, :utc_datetime
    end

    alter table(:workspaces) do
      add :sponsorship_tiers, :map, null: false, default: fragment("'[]'::jsonb")
      add :sponsorship_deadline, :utc_datetime
    end

    create table(:sponsorships, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :level, :text, null: false

      add :workspace_id,
          references(:workspaces, type: :uuid, on_delete: :delete_all),
          null: false

      add :event_id, references(:events, type: :uuid, on_delete: :delete_all)
      add :sponsor_user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :workflow_run_id, references(:workflow_runs, type: :uuid, on_delete: :nilify_all)

      add :tier_id, :uuid
      add :tier_name, :text
      add :status, :text, null: false, default: "pending"

      add :amount, :bigint
      add :company_name, :text, null: false
      add :contact_email, :text, null: false
      add :contact_phone, :text
      add :message, :text

      add :approved_by, references(:users, type: :uuid, on_delete: :nilify_all)
      add :approved_at, :utc_datetime
      add :rejection_reason, :text
      add :approval_deadline, :utc_datetime
      add :expired_at, :utc_datetime
      add :started_at, :utc_datetime
      add :ended_at, :utc_datetime

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sponsorships, [:level, :event_id, :sponsor_user_id],
             name: "sponsorships_unique_event_sponsor_index",
             where: "level = 'event' AND status IN ('pending', 'active')"
           )

    create unique_index(:sponsorships, [:level, :workspace_id, :sponsor_user_id],
             name: "sponsorships_unique_workspace_sponsor_index",
             where: "level = 'workspace' AND status IN ('pending', 'active')"
           )

    create index(:sponsorships, [:workspace_id, :status, :approval_deadline])
    create index(:sponsorships, [:event_id, :status])
    create index(:sponsorships, [:sponsor_user_id, :status])

    create constraint(:sponsorships, :sponsorships_level_target_consistency,
             check: "(level = 'event') = (event_id IS NOT NULL)"
           )

    create table(:sponsorship_deliveries, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :workspace_id,
          references(:workspaces, type: :uuid, on_delete: :delete_all),
          null: false

      add :sponsorship_id,
          references(:sponsorships, type: :uuid, on_delete: :delete_all),
          null: false

      add :benefit, :text, null: false
      add :due_date, :utc_datetime
      add :fulfilled_at, :utc_datetime
      add :proof_note, :text
      add :exclusive, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sponsorship_deliveries, [:sponsorship_id, :fulfilled_at])
  end

  def down do
    drop(table(:sponsorship_deliveries))
    drop(table(:sponsorships))

    alter table(:workspaces) do
      remove :sponsorship_tiers
      remove :sponsorship_deadline
    end

    alter table(:events) do
      remove :sponsorship_enabled
      remove :sponsorship_tiers
      remove :sponsorship_deadline
    end
  end
end
