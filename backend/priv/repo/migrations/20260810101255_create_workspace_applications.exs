defmodule Cgc2046.Repo.Migrations.CreateWorkspaceApplications do
  @moduledoc """
  Creates workspace_applications table for WorkspaceApplication resource
  （Platform Admin Dashboard R6/R7：用户申请创建工作台，platform_admin 审批）。

  全局资源（无 workspace_id——workspace 尚不存在）。审批生命周期与 JoinRequest 一致：
  pending → approved/rejected/expired，approval_deadline 默认 7 天由 create action 写入，
  Oban ApprovalExpiryWorker 扫描过期。
  """

  use Ecto.Migration

  def change do
    create table(:workspace_applications, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :applicant_id,
          references(:users,
            column: :id,
            name: "workspace_applications_applicant_id_fkey",
            type: :uuid,
            prefix: "public"
          ),
          null: false

      add :name, :text, null: false
      add :slug, :text, null: false
      add :purpose, :text, null: false

      add :status, :text, null: false, default: "pending"
      add :rejection_reason, :text
      add :approved_by, :uuid
      add :approved_at, :utc_datetime
      add :approval_deadline, :utc_datetime
      add :expired_at, :utc_datetime

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    # 申请人查询自己的申请（read policy：applicant_id == actor.id）
    create index(:workspace_applications, [:applicant_id])

    # Oban 过期扫描：status == pending and approval_deadline < now
    create index(:workspace_applications, [:status])
    create index(:workspace_applications, [:approval_deadline])
  end
end
