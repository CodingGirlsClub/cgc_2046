defmodule Cgc2046.Repo.Migrations.AddFksForRegisteredBelongsTo do
  @moduledoc """
  #745 B 类：resource 声明了 belongs_to 但 DB 无 FK 的 9 列补约束（真 DDL，
  与 #724 的零 DDL 追平互补）。`@no_db_fk_relationships` 登记清单随之清空。

  每列三步：孤儿防御清理（幂等）→ 补缺失索引 → 加约束。约束名与 snapshot
  记录名逐字一致（Ecto 默认 `table_column_fkey`）。

  on_delete 裁决（逐列业务语义，编排者 2026-09-18 批复）：
  - invitations.inviter_id :delete —— 邀请随邀请人死（NOT NULL 不可 nilify；
    先例 speaker_invitations.invited_by delete_all）
  - invitations.accepted_by :nilify —— 归因列，删号清归因留邀请记录
    （同 events.created_by 先例）
  - portfolio_items.workspace_id / workspace_profiles.{workspace_id,user_id} /
    mcp_{pending_operations,tokens,tool_call_logs}.user_id :delete —— 条目随
    所属租户/用户死（ADR-0004 挂账项落地；users 无 destroy action，前向防御）
  - curriculum_outputs.workflow_run_id :nilify —— 与三个兄弟表的可空
    workflow_run_id FK（enrollments/sponsorships/speaker_invitations）同取
    nilify：run 只 cancel 不 destroy，未来若 destroy 则留工件清归因

  活表纪律（AGENTS.md）：mcp_tool_call_logs 是增长最快的 append-only 面，
  其 FK 走 NOT VALID + VALIDATE 两段式；其余 8 列小表一次到位。
  down：约束/索引可逆；被清理的孤儿行不可逆（孤儿本即无效数据，改前实测
  本库 9 语句影响行数全 0）。
  """

  use Ecto.Migration

  def up do
    # ── 1) 孤儿防御清理（幂等；部署不依赖合并前的存量扫描时点）──────────
    execute(
      "UPDATE invitations i SET accepted_by = NULL WHERE i.accepted_by IS NOT NULL AND " <>
        "NOT EXISTS (SELECT 1 FROM users u WHERE u.id = i.accepted_by)"
    )

    execute(
      "DELETE FROM invitations i WHERE i.inviter_id IS NOT NULL AND " <>
        "NOT EXISTS (SELECT 1 FROM users u WHERE u.id = i.inviter_id)"
    )

    # curriculum_outputs.workflow_run_id 为 :nilify 桶：孤儿清归因不删行（与
    # 约束动作一致；drill 演练发现误写 DELETE 已修——nilify 列若先 DELETE，
    # 行为静默变成 :delete，违背裁决语义）
    execute(
      "UPDATE curriculum_outputs c SET workflow_run_id = NULL WHERE c.workflow_run_id IS NOT NULL AND " <>
        "NOT EXISTS (SELECT 1 FROM workflow_runs w WHERE w.id = c.workflow_run_id)"
    )

    execute(
      "DELETE FROM portfolio_items p WHERE p.workspace_id IS NOT NULL AND " <>
        "NOT EXISTS (SELECT 1 FROM workspaces k WHERE k.id = p.workspace_id)"
    )

    execute(
      "DELETE FROM workspace_profiles wp WHERE wp.workspace_id IS NOT NULL AND " <>
        "NOT EXISTS (SELECT 1 FROM workspaces k WHERE k.id = wp.workspace_id)"
    )

    execute(
      "DELETE FROM workspace_profiles wp WHERE wp.user_id IS NOT NULL AND " <>
        "NOT EXISTS (SELECT 1 FROM users u WHERE u.id = wp.user_id)"
    )

    execute(
      "DELETE FROM mcp_pending_operations m WHERE m.user_id IS NOT NULL AND " <>
        "NOT EXISTS (SELECT 1 FROM users u WHERE u.id = m.user_id)"
    )

    execute(
      "DELETE FROM mcp_tokens t WHERE t.user_id IS NOT NULL AND " <>
        "NOT EXISTS (SELECT 1 FROM users u WHERE u.id = t.user_id)"
    )

    execute(
      "DELETE FROM mcp_tool_call_logs l WHERE l.user_id IS NOT NULL AND " <>
        "NOT EXISTS (SELECT 1 FROM users u WHERE u.id = l.user_id)"
    )

    # ── 2) 补缺失的 FK 列索引（FK 检查用；皆小表，无需 concurrently）────
    create index(:curriculum_outputs, [:workflow_run_id],
             name: :curriculum_outputs_workflow_run_id_index
           )

    create index(:invitations, [:inviter_id], name: :invitations_inviter_id_index)
    create index(:invitations, [:accepted_by], name: :invitations_accepted_by_index)
    create index(:portfolio_items, [:workspace_id], name: :portfolio_items_workspace_id_index)

    # ── 3) FK 约束（8 列小表一次到位）──────────────────────────────────
    alter table(:curriculum_outputs) do
      modify :workflow_run_id,
             references(:workflow_runs,
               column: :id,
               type: :uuid,
               on_delete: :nilify_all
             ),
             from: :uuid
    end

    alter table(:invitations) do
      modify :inviter_id,
             references(:users,
               column: :id,
               type: :uuid,
               on_delete: :delete_all
             ),
             from: :uuid
    end

    alter table(:invitations) do
      modify :accepted_by,
             references(:users,
               column: :id,
               type: :uuid,
               on_delete: :nilify_all
             ),
             from: :uuid
    end

    alter table(:portfolio_items) do
      modify :workspace_id,
             references(:workspaces,
               column: :id,
               type: :uuid,
               on_delete: :delete_all
             ),
             from: :uuid
    end

    alter table(:workspace_profiles) do
      modify :workspace_id,
             references(:workspaces,
               column: :id,
               type: :uuid,
               on_delete: :delete_all
             ),
             from: :uuid
    end

    alter table(:workspace_profiles) do
      modify :user_id,
             references(:users,
               column: :id,
               type: :uuid,
               on_delete: :delete_all
             ),
             from: :uuid
    end

    alter table(:mcp_pending_operations) do
      modify :user_id,
             references(:users,
               column: :id,
               type: :uuid,
               on_delete: :delete_all
             ),
             from: :uuid
    end

    alter table(:mcp_tokens) do
      modify :user_id,
             references(:users,
               column: :id,
               type: :uuid,
               on_delete: :delete_all
             ),
             from: :uuid
    end

    # mcp_tool_call_logs（活表）：NOT VALID + VALIDATE 两段式，
    # 约束名与 snapshot 记录的默认名逐字一致。
    execute(
      "ALTER TABLE mcp_tool_call_logs " <>
        "ADD CONSTRAINT mcp_tool_call_logs_user_id_fkey " <>
        "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE NOT VALID"
    )

    execute("ALTER TABLE mcp_tool_call_logs VALIDATE CONSTRAINT mcp_tool_call_logs_user_id_fkey")
  end

  def down do
    execute("ALTER TABLE mcp_tool_call_logs DROP CONSTRAINT mcp_tool_call_logs_user_id_fkey")

    alter table(:mcp_tokens) do
      modify(:user_id, :uuid)
    end

    alter table(:mcp_pending_operations) do
      modify(:user_id, :uuid)
    end

    alter table(:workspace_profiles) do
      modify(:user_id, :uuid)
    end

    alter table(:workspace_profiles) do
      modify(:workspace_id, :uuid)
    end

    alter table(:portfolio_items) do
      modify(:workspace_id, :uuid)
    end

    alter table(:invitations) do
      modify(:accepted_by, :uuid)
    end

    alter table(:invitations) do
      modify(:inviter_id, :uuid)
    end

    alter table(:curriculum_outputs) do
      modify(:workflow_run_id, :uuid)
    end

    drop index(:portfolio_items, [:workspace_id], name: :portfolio_items_workspace_id_index)
    drop index(:invitations, [:accepted_by], name: :invitations_accepted_by_index)
    drop index(:invitations, [:inviter_id], name: :invitations_inviter_id_index)

    drop index(:curriculum_outputs, [:workflow_run_id],
           name: :curriculum_outputs_workflow_run_id_index
         )
  end
end
