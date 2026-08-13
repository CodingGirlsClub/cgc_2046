defmodule Cgc2046.Repo.Migrations.CreateSpeakerInvitations do
  use Ecto.Migration

  def change do
    # E-4 #49 SpeakerInvitation：Event 级逐人定向邀请（邀请 workflow v1.1 定稿）。
    # token 只存 SHA256 哈希（明文仅在创建响应出现一次）；唯一性由
    # (event_id, speaker_email) 未终态部分唯一索引 + token_hash 唯一索引兜底。
    create table(:speaker_invitations, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :workspace_id,
          references(:workspaces, type: :uuid, on_delete: :delete_all),
          null: false

      add :event_id, references(:events, type: :uuid, on_delete: :delete_all), null: false
      add :speaker_user_id, references(:users, type: :uuid, on_delete: :delete_all)
      add :speaker_name, :text, null: false
      add :speaker_email, :text
      add :topic, :text
      add :scheduled_at, :utc_datetime
      add :note, :text
      add :invited_by, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :token_hash, :text, null: false
      add :status, :text, null: false, default: "invited"
      add :accepted_by, references(:users, type: :uuid, on_delete: :delete_all)
      add :accepted_at, :utc_datetime
      add :declined_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :expires_at, :utc_datetime

      add :workflow_run_id,
          references(:workflow_runs, type: :uuid, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:speaker_invitations, [:token_hash],
             name: "speaker_invitations_unique_token_hash_index"
           )

    # 同一 Event 同一 speaker_email 的未终态（invited/accepted）邀请唯一；
    # declined/completed 为终态，允许重邀。speaker_email 为 NULL（手动转发
    # 链接）不参与唯一性（与 ash resource identity_wheres_to_sql 对齐）。
    create unique_index(:speaker_invitations, [:event_id, :speaker_email],
             name: "speaker_invitations_unique_event_email_index",
             where: "speaker_email IS NOT NULL AND status IN ('invited', 'accepted')"
           )

    create index(:speaker_invitations, [:workspace_id])
    create index(:speaker_invitations, [:event_id])
  end
end
