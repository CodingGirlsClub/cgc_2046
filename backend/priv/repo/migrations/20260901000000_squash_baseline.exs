defmodule Cgc2046.Repo.Migrations.SquashBaseline do
  @moduledoc """
  Squash baseline：2026-08-20 将 46 个历史 migration（2026-08-01 → 08-19）压缩为
  单文件全量基线（未部署窗口期，git 历史即归档）。

  范围：43 张应用表 + ENUM `phone_verification_purpose` + 全部索引 / FK / CHECK 约束。
  不在本文件（保持独立迁移）：
  - `20260801074651` extensions（ash-functions / citext）——本 baseline 的
    uuid 默认值依赖 gen_random_uuid()（PG 13+ 核心函数），citext 列（users.email）
    依赖 citext 扩展，须先于本文件执行；
  - `20260808125000` Oban（oban_jobs / oban_peers / oban_job_state ENUM）。

  生成与核对：以 squash 前迁移链跑出的 dev 库最终 schema 为准（catalog 直读 +
  pg_dump 对照），并经「重建后 pg_dump 逐行 diff 等价」验证。Ash resource 定义是
  真相源，本文件只是其投影；后续 schema 变更一律走新增 migration，不回改本文件。

  down：按依赖逆序 drop 全部表 + ENUM（只恢复结构，不涉及数据）。
  """

  use Ecto.Migration

  def up do
    execute "CREATE TYPE phone_verification_purpose AS ENUM ('login', 'wechat_bind')"

    create table(:admin_action_logs, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true
      add :actor_id, :uuid
      add :action, :text, null: false
      add :target_type, :text, null: false
      add :target_id, :uuid, null: false
      add :result, :text, default: "success", null: false
      add :metadata, :map, default: %{}, null: false

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create table(:jido_checkpoints, primary_key: false) do
      add :key_bytea, :binary, null: false, primary_key: true
      add :data_bytea, :binary, null: false

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create table(:jido_thread_entries, primary_key: false) do
      add :thread_id, :string, size: 255, null: false, primary_key: true
      add :seq, :bigint, null: false, primary_key: true
      add :entry_bytea, :binary, null: false

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create table(:jido_thread_meta, primary_key: false) do
      add :thread_id, :string, size: 255, null: false, primary_key: true
      add :rev, :bigint, default: 0, null: false
      add :metadata_bytea, :binary
      add :created_at, :bigint
      add :updated_at, :bigint
    end

    create table(:mcp_pending_operations, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :user_id, :uuid, null: false
      add :tool, :text, null: false
      add :params, :map, null: false
      add :summary, :text, null: false
      add :status, :text, null: false
      add :expires_at, :utc_datetime, null: false
      add :resolved_at, :utc_datetime
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:mcp_tokens, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :token_hash, :text, null: false
      add :name, :text, null: false
      add :user_id, :uuid, null: false
      add :last_used_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:mcp_tool_call_logs, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :user_id, :uuid, null: false
      add :tool, :text, null: false
      add :params, :map, null: false
      add :result_status, :text, null: false
      add :error_message, :text
      add :latency_ms, :bigint
      add :pending_operation_id, :uuid
      add :inserted_at, :utc_datetime_usec, null: false
      add :client_name, :text
      add :session_id, :text
    end

    create table(:miniprogram_code_daily_quotas, primary_key: false) do
      add :platform, :text, null: false
      add :quota_date, :date, null: false
      add :used, :bigint, null: false
    end

    create table(:miniprogram_share_schemes, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true
      add :target_kind, :text, null: false
      add :target_id, :uuid, null: false
      add :platform, :text, null: false
      add :openlink, :text, null: false
      add :expires_at, :utc_datetime, null: false

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create table(:payments_webhook_events, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true
      add :provider, :text, null: false
      add :event_id, :text, null: false
      add :payload, :map, default: %{}, null: false
      add :status, :text, default: "received", null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:phone_verification_codes, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :phone, :text, null: false
      add :code_hash, :text, null: false
      add :purpose, :phone_verification_purpose, null: false
      add :expires_at, :utc_datetime, null: false
      add :attempts_left, :integer, default: 3, null: false
      add :consumed_at, :utc_datetime
      add :send_request_id, :text, null: false
      add :inserted_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
    end

    create table(:reconciliation_findings, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true
      add :rule, :text, null: false
      add :entity_type, :text, null: false
      add :entity_id, :string, size: 255, null: false
      add :workspace_id, :uuid
      add :detail, :map, default: %{}, null: false
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:roles, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true
      add :workspace_id, :uuid, null: false
      add :name, :text, null: false
      add :description, :text

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create table(:signal_logs, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true
      add :workspace_id, :uuid, null: false
      add :run_id, :uuid, null: false
      add :signal_type, :text, null: false
      add :payload, :map, default: %{}
      add :actor_id, :uuid
      add :received_at, :utc_datetime_usec, null: false

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create table(:tokens, primary_key: false) do
      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :created_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :extra_data, :map
      add :purpose, :text, null: false
      add :expires_at, :utc_datetime, null: false
      add :subject, :text, null: false
      add :jti, :text, null: false, primary_key: true
    end

    create table(:users, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true
      add :email, :citext
      add :hashed_password, :text
      add :is_platform_admin, :boolean, default: false, null: false

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :display_name, :string, size: 255
      add :phone, :text
      add :locale, :text
    end

    create table(:wechat_login_tickets, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :state, :text, null: false
      add :openid, :text
      add :unionid, :text
      add :access_token, :text
      add :status, :text, default: "pending", null: false
      add :expires_at, :utc_datetime, null: false
      add :inserted_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
    end

    create table(:workspace_profiles, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true
      add :workspace_id, :uuid, null: false
      add :user_id, :uuid, null: false
      add :avatar_url, :text
      add :location, :text
      add :about, :text
      add :skills, {:array, :text}, default: []
      add :visibility, :text, default: "only_me", null: false
      add :ui_theme_preference, :string, size: 255, default: "dark", null: false

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create table(:workspaces, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true
      add :slug, :text, null: false
      add :name, :text, null: false
      add :join_policy, :text, default: "request", null: false
      add :sponsorship_enabled, :boolean, default: true, null: false

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :sponsorship_tiers, :map, default: fragment("'[]'::jsonb"), null: false
      add :sponsorship_deadline, :utc_datetime
    end

    create table(:invitations, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true

      add :workspace_id,
          references(:workspaces,
            column: :id,
            type: :uuid,
            name: "invitations_workspace_id_fkey"
          ),
          null: false

      add :token_hash, :text, null: false
      add :inviter_id, :uuid, null: false
      add :target_email, :text
      add :preauthorized_role_names, {:array, :text}
      add :expires_at, :utc_datetime
      add :status, :text, default: "active", null: false
      add :accepted_by, :uuid
      add :accepted_at, :utc_datetime

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create table(:join_requests, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true

      add :workspace_id,
          references(:workspaces,
            column: :id,
            type: :uuid,
            name: "join_requests_workspace_id_fkey"
          ),
          null: false

      add :user_id,
          references(:users, column: :id, type: :uuid, name: "join_requests_user_id_fkey"),
          null: false

      add :status, :text, default: "pending", null: false
      add :message, :text
      add :approved_by, :uuid
      add :approved_at, :utc_datetime
      add :rejection_reason, :text
      add :approval_deadline, :utc_datetime
      add :expired_at, :utc_datetime

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create table(:mp_notification_consents, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true

      add :user_id,
          references(:users,
            column: :id,
            type: :uuid,
            name: "mp_notification_consents_user_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :platform, :text, null: false
      add :template_key, :text, null: false
      add :remaining_uses, :bigint, default: 0, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:portfolio_items, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true

      add :user_id,
          references(:users,
            column: :id,
            type: :uuid,
            name: "portfolio_items_user_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :title, :text, null: false
      add :description, :text
      add :url, :text
      add :icon, :text, default: "document", null: false
      add :inserted_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
      add :workspace_id, :uuid, null: false
    end

    create table(:curriculum_outputs, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true

      add :workspace_id,
          references(:workspaces,
            column: :id,
            type: :uuid,
            name: "curriculum_outputs_workspace_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :key, :text, null: false
      add :kind, :text, null: false
      add :data, :map, null: false
      add :submitted_by, :uuid, null: false
      add :workflow_run_id, :uuid

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create table(:signal_idempotency, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true

      add :workspace_id,
          references(:workspaces,
            column: :id,
            type: :uuid,
            name: "signal_idempotency_workspace_id_fkey",
            on_delete: :delete_all
          )

      add :signal_type, :text, null: false
      add :idempotency_key, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create table(:user_identities, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true
      add :provider, :text, null: false
      add :uid, :text, null: false
      add :unionid, :text

      add :user_id,
          references(:users,
            column: :id,
            type: :uuid,
            name: "user_identities_user_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create table(:workflow_definitions, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true

      add :workspace_id,
          references(:workspaces,
            column: :id,
            type: :uuid,
            name: "workflow_definitions_workspace_id_fkey"
          ),
          null: false

      add :name, :text, null: false
      add :type, :text, null: false
      add :version, :bigint, default: 1, null: false
      add :status, :text, default: "draft", null: false
      add :input_schema, :map
      add :node_def, :map
      add :approval_timeout, :bigint

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create table(:workspace_applications, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true

      add :applicant_id,
          references(:users,
            column: :id,
            type: :uuid,
            name: "workspace_applications_applicant_id_fkey"
          ),
          null: false

      add :name, :text, null: false
      add :slug, :text, null: false
      add :purpose, :text, null: false
      add :status, :text, default: "pending", null: false
      add :rejection_reason, :text
      add :approved_by, :uuid
      add :approved_at, :utc_datetime
      add :approval_deadline, :utc_datetime
      add :expired_at, :utc_datetime

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :rejected_by, :uuid
      add :rejected_at, :utc_datetime
    end

    create table(:workspace_memberships, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true

      add :workspace_id,
          references(:workspaces,
            column: :id,
            type: :uuid,
            name: "workspace_memberships_workspace_id_fkey"
          ),
          null: false

      add :user_id,
          references(:users,
            column: :id,
            type: :uuid,
            name: "workspace_memberships_user_id_fkey"
          ),
          null: false

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create table(:membership_roles, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true
      add :workspace_id, :uuid, null: false

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :membership_id,
          references(:workspace_memberships,
            column: :id,
            type: :uuid,
            name: "membership_roles_membership_id_fkey"
          ),
          null: false

      add :role_id,
          references(:roles, column: :id, type: :uuid, name: "membership_roles_role_id_fkey"),
          null: false
    end

    create table(:miniprogram_codes, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true

      add :workspace_id,
          references(:workspaces,
            column: :id,
            type: :uuid,
            name: "miniprogram_codes_workspace_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :invitation_id,
          references(:invitations,
            column: :id,
            type: :uuid,
            name: "miniprogram_codes_invitation_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :platform, :text, null: false
      add :scene, :text, null: false
      add :code, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create table(:workflow_runs, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true
      add :workspace_id, :uuid, null: false

      add :definition_id,
          references(:workflow_definitions,
            column: :id,
            type: :uuid,
            name: "workflow_runs_definition_id_fkey"
          ),
          null: false

      add :definition_version, :bigint, null: false
      add :status, :text, default: "pending", null: false
      add :input_snapshot, :map
      add :facts, :map, default: %{}
      add :partition_id, :uuid
      add :version, :bigint, default: 1, null: false
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create table(:workflow_steps, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true
      add :workspace_id, :uuid, null: false

      add :definition_id,
          references(:workflow_definitions,
            column: :id,
            type: :uuid,
            name: "workflow_steps_definition_id_fkey"
          ),
          null: false

      add :step_key, :text, null: false
      add :title, :text, null: false
      add :type, :text, null: false
      add :action, :text
      add :sub_definition_id, :uuid
      add :input_schema, :map

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create table(:courses, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true

      add :workspace_id,
          references(:workspaces, column: :id, type: :uuid, name: "courses_workspace_id_fkey"),
          null: false

      add :title, :text, null: false
      add :curriculum_requirements, :map, default: %{}
      add :status, :text, default: "draft", null: false

      add :workflow_run_id,
          references(:workflow_runs,
            column: :id,
            type: :uuid,
            name: "courses_workflow_run_id_fkey"
          )

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :enrollment_policy, :text, default: "open", null: false
      add :capacity, :bigint
      add :confirmed_count, :bigint, default: 0, null: false
      add :registration_deadline, :utc_datetime
      add :visibility, :string, size: 255, default: "public", null: false
      add :slug, :string, size: 255, null: false
      add :description, :text
      add :pricing_enabled, :boolean, default: false, null: false
      add :price_tiers, :map, default: fragment("'[]'::jsonb"), null: false
    end

    create table(:events, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true

      add :workspace_id,
          references(:workspaces, column: :id, type: :uuid, name: "events_workspace_id_fkey"),
          null: false

      add :title, :text, null: false
      add :curriculum_enabled, :boolean, default: true, null: false
      add :curriculum_requirements, :map, default: %{}
      add :status, :text, default: "draft", null: false

      add :workflow_run_id,
          references(:workflow_runs,
            column: :id,
            type: :uuid,
            name: "events_workflow_run_id_fkey"
          )

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :enrollment_policy, :text, default: "open", null: false
      add :capacity, :bigint
      add :confirmed_count, :bigint, default: 0, null: false
      add :registration_deadline, :utc_datetime
      add :visibility, :string, size: 255, default: "public", null: false
      add :slug, :string, size: 255, null: false
      add :description, :text
      add :sponsorship_enabled, :boolean, default: true, null: false
      add :sponsorship_tiers, :map, default: fragment("'[]'::jsonb"), null: false
      add :sponsorship_deadline, :utc_datetime
      add :pricing_enabled, :boolean, default: false, null: false
      add :price_tiers, :map, default: fragment("'[]'::jsonb"), null: false
    end

    create table(:workflow_step_roles, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true
      add :workspace_id, :uuid, null: false

      add :step_id,
          references(:workflow_steps,
            column: :id,
            type: :uuid,
            name: "workflow_step_roles_step_id_fkey"
          ),
          null: false

      add :role_id,
          references(:roles, column: :id, type: :uuid, name: "workflow_step_roles_role_id_fkey"),
          null: false

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create table(:invite_batches, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true

      add :workspace_id,
          references(:workspaces,
            column: :id,
            type: :uuid,
            name: "invite_batches_workspace_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :event_id,
          references(:events,
            column: :id,
            type: :uuid,
            name: "invite_batches_event_id_fkey",
            on_delete: :delete_all
          )

      add :course_id,
          references(:courses,
            column: :id,
            type: :uuid,
            name: "invite_batches_course_id_fkey",
            on_delete: :delete_all
          )

      add :invite_code, :text, null: false
      add :quota, :bigint, null: false
      add :remaining_quota, :bigint, null: false
      add :expires_at, :utc_datetime
      add :status, :text, default: "active", null: false
      add :remark, :text
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:learning_records, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true

      add :workspace_id,
          references(:workspaces,
            column: :id,
            type: :uuid,
            name: "learning_records_workspace_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :course_id,
          references(:courses,
            column: :id,
            type: :uuid,
            name: "learning_records_course_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :user_id, :uuid, null: false
      add :issue_id, :text, null: false
      add :item_id, :text, null: false
      add :done, :boolean, default: false, null: false
      add :evidence, :text
      add :recorded_at, :utc_datetime_usec, null: false
      add :enrollment_id, :uuid
      add :run_id, :uuid

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create table(:speaker_invitations, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true

      add :workspace_id,
          references(:workspaces,
            column: :id,
            type: :uuid,
            name: "speaker_invitations_workspace_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :event_id,
          references(:events,
            column: :id,
            type: :uuid,
            name: "speaker_invitations_event_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :speaker_user_id,
          references(:users,
            column: :id,
            type: :uuid,
            name: "speaker_invitations_speaker_user_id_fkey",
            on_delete: :delete_all
          )

      add :speaker_name, :text, null: false
      add :speaker_email, :text
      add :topic, :text
      add :scheduled_at, :utc_datetime
      add :note, :text

      add :invited_by,
          references(:users,
            column: :id,
            type: :uuid,
            name: "speaker_invitations_invited_by_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :token_hash, :text, null: false
      add :status, :text, default: "invited", null: false

      add :accepted_by,
          references(:users,
            column: :id,
            type: :uuid,
            name: "speaker_invitations_accepted_by_fkey",
            on_delete: :delete_all
          )

      add :accepted_at, :utc_datetime
      add :declined_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :expires_at, :utc_datetime

      add :workflow_run_id,
          references(:workflow_runs,
            column: :id,
            type: :uuid,
            name: "speaker_invitations_workflow_run_id_fkey",
            on_delete: :nilify_all
          )

      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:sponsorships, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true
      add :level, :text, null: false

      add :workspace_id,
          references(:workspaces,
            column: :id,
            type: :uuid,
            name: "sponsorships_workspace_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :event_id,
          references(:events,
            column: :id,
            type: :uuid,
            name: "sponsorships_event_id_fkey",
            on_delete: :delete_all
          )

      add :sponsor_user_id,
          references(:users,
            column: :id,
            type: :uuid,
            name: "sponsorships_sponsor_user_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :workflow_run_id,
          references(:workflow_runs,
            column: :id,
            type: :uuid,
            name: "sponsorships_workflow_run_id_fkey",
            on_delete: :nilify_all
          )

      add :tier_id, :uuid
      add :tier_name, :text
      add :status, :text, default: "pending", null: false
      add :amount, :bigint
      add :company_name, :text, null: false
      add :contact_email, :text, null: false
      add :contact_phone, :text
      add :message, :text

      add :approved_by,
          references(:users,
            column: :id,
            type: :uuid,
            name: "sponsorships_approved_by_fkey",
            on_delete: :nilify_all
          )

      add :approved_at, :utc_datetime
      add :rejection_reason, :text
      add :approval_deadline, :utc_datetime
      add :expired_at, :utc_datetime
      add :started_at, :utc_datetime
      add :ended_at, :utc_datetime
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:enrollments, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true

      add :workspace_id,
          references(:workspaces,
            column: :id,
            type: :uuid,
            name: "enrollments_workspace_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :event_id,
          references(:events,
            column: :id,
            type: :uuid,
            name: "enrollments_event_id_fkey",
            on_delete: :delete_all
          )

      add :course_id,
          references(:courses,
            column: :id,
            type: :uuid,
            name: "enrollments_course_id_fkey",
            on_delete: :delete_all
          )

      add :user_id,
          references(:users,
            column: :id,
            type: :uuid,
            name: "enrollments_user_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :workflow_run_id,
          references(:workflow_runs,
            column: :id,
            type: :uuid,
            name: "enrollments_workflow_run_id_fkey",
            on_delete: :nilify_all
          )

      add :invite_batch_id,
          references(:invite_batches,
            column: :id,
            type: :uuid,
            name: "enrollments_invite_batch_id_fkey",
            on_delete: :nilify_all
          )

      add :status, :text, default: "pending", null: false
      add :submission_payload, :map, default: %{}, null: false
      add :capacity_seq, :bigint

      add :approved_by,
          references(:users,
            column: :id,
            type: :uuid,
            name: "enrollments_approved_by_fkey",
            on_delete: :nilify_all
          )

      add :approved_at, :utc_datetime
      add :rejection_reason, :text
      add :approval_deadline, :utc_datetime
      add :expired_at, :utc_datetime
      add :cancelled_at, :utc_datetime
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:sponsorship_deliveries, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true

      add :workspace_id,
          references(:workspaces,
            column: :id,
            type: :uuid,
            name: "sponsorship_deliveries_workspace_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :sponsorship_id,
          references(:sponsorships,
            column: :id,
            type: :uuid,
            name: "sponsorship_deliveries_sponsorship_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :benefit, :text, null: false
      add :due_date, :utc_datetime
      add :fulfilled_at, :utc_datetime
      add :proof_note, :text
      add :exclusive, :boolean, default: false, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:payments_orders, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true

      add :workspace_id,
          references(:workspaces,
            column: :id,
            type: :uuid,
            name: "payments_orders_workspace_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :enrollment_id,
          references(:enrollments,
            column: :id,
            type: :uuid,
            name: "payments_orders_enrollment_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :provider, :text, null: false
      add :out_trade_no, :text, null: false
      add :transaction_id, :text
      add :amount_cents, :bigint, null: false
      add :tier_snapshot, :map, default: %{}, null: false
      add :status, :text, default: "pending", null: false
      add :expire_at, :utc_datetime, null: false
      add :refunded_at, :utc_datetime
      add :cancel_reason, :text
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:admin_action_logs, [:action], name: "admin_action_logs_action_index")

    create index(:admin_action_logs, [:target_type, :target_id],
             name: "admin_action_logs_target_type_target_id_index"
           )

    create index(:mcp_pending_operations, [:user_id],
             name: "mcp_pending_operations_user_id_index"
           )

    create unique_index(:mcp_tokens, [:token_hash], name: "mcp_tokens_token_hash_index")
    create index(:mcp_tokens, [:user_id], name: "mcp_tokens_user_id_index")

    create index(:mcp_tool_call_logs, [:tool], name: "mcp_tool_call_logs_tool_index")
    create index(:mcp_tool_call_logs, [:user_id], name: "mcp_tool_call_logs_user_id_index")

    create unique_index(:miniprogram_code_daily_quotas, [:platform, :quota_date],
             name: "miniprogram_code_daily_quotas_platform_quota_date_index"
           )

    create unique_index(:miniprogram_share_schemes, [:target_kind, :target_id, :platform],
             name: "miniprogram_share_schemes_unique_target_platform_index"
           )

    create unique_index(:payments_webhook_events, [:provider, :event_id],
             name: "payments_webhook_events_unique_provider_event_index"
           )

    create index(:phone_verification_codes, [:phone, :purpose],
             name: "phone_verification_codes_active_idx",
             where: "(consumed_at IS NULL)"
           )

    create index(:phone_verification_codes, [:expires_at],
             name: "phone_verification_codes_expires_at_index"
           )

    create index(:reconciliation_findings, [:rule, :last_seen_at],
             name: "reconciliation_findings_rule_last_seen_at_index"
           )

    create unique_index(:reconciliation_findings, [:rule, :entity_type, :entity_id],
             name: "reconciliation_findings_unique_finding_index"
           )

    create index(:reconciliation_findings, [:workspace_id],
             name: "reconciliation_findings_workspace_id_index"
           )

    create unique_index(:roles, [:workspace_id, :name],
             name: "roles_unique_role_per_workspace_index"
           )

    create index(:signal_logs, [:workspace_id, :run_id],
             name: "signal_logs_workspace_id_run_id_index"
           )

    create unique_index(:users, [:email], name: "users_unique_email_index")

    create unique_index(:users, [:phone],
             name: "users_unique_phone_index",
             where: "(phone IS NOT NULL)"
           )

    create index(:wechat_login_tickets, [:expires_at],
             name: "wechat_login_tickets_expires_at_index"
           )

    create unique_index(:wechat_login_tickets, [:state], name: "wechat_login_tickets_state_index")

    create index(:workspace_profiles, [:user_id], name: "workspace_profiles_user_id_index")

    create unique_index(:workspace_profiles, [:workspace_id, :user_id],
             name: "wsp_unique_ws_user_idx"
           )

    create unique_index(:workspaces, [:slug], name: "workspaces_unique_slug_index")

    create unique_index(:invitations, [:token_hash], name: "invitations_unique_token_hash_index")

    create unique_index(:join_requests, [:workspace_id, :user_id],
             name: "join_requests_unique_pending_join_request_per_ws_user_index",
             where: "(status = 'pending'::text)"
           )

    create unique_index(:mp_notification_consents, [:user_id, :platform, :template_key],
             name: "mp_notification_consents_unique_user_platform_template_index"
           )

    create constraint(:mp_notification_consents, :mp_notification_consents_non_negative,
             check: "(remaining_uses >= 0)"
           )

    create index(:portfolio_items, [:user_id], name: "portfolio_items_user_id_index")

    create unique_index(:curriculum_outputs, [:key, :kind],
             name: "curriculum_outputs_unique_key_kind_index"
           )

    create index(:curriculum_outputs, [:workspace_id],
             name: "curriculum_outputs_workspace_id_index"
           )

    create index(:signal_idempotency, [:inserted_at],
             name: "signal_idempotency_inserted_at_index"
           )

    create unique_index(:signal_idempotency, [:signal_type, :idempotency_key],
             name: "signal_idempotency_unique_signal_key_index"
           )

    create index(:signal_idempotency, [:workspace_id],
             name: "signal_idempotency_workspace_id_index"
           )

    create unique_index(:user_identities, [:provider, :uid],
             name: "user_identities_unique_provider_uid_index"
           )

    create unique_index(:workflow_definitions, [:workspace_id, :name, :version],
             name: "workflow_definitions_unique_name_version_per_workspace_index"
           )

    create index(:workflow_definitions, [:workspace_id],
             name: "workflow_definitions_workspace_id_index"
           )

    create index(:workspace_applications, [:applicant_id],
             name: "workspace_applications_applicant_id_index"
           )

    create index(:workspace_applications, [:approval_deadline],
             name: "workspace_applications_approval_deadline_index"
           )

    create index(:workspace_applications, [:status], name: "workspace_applications_status_index")

    create unique_index(:workspace_memberships, [:workspace_id, :user_id],
             name: "wm_unique_ws_user_idx"
           )

    create unique_index(:membership_roles, [:workspace_id, :membership_id, :role_id],
             name: "membership_roles_unique_membership_role_index"
           )

    create unique_index(:miniprogram_codes, [:invitation_id, :platform],
             name: "miniprogram_codes_unique_invitation_platform_index"
           )

    create unique_index(:miniprogram_codes, [:scene],
             name: "miniprogram_codes_unique_scene_index"
           )

    create unique_index(:workflow_steps, [:workspace_id, :definition_id, :step_key],
             name: "workflow_steps_unique_step_key_per_definition_index"
           )

    create unique_index(:courses, [:slug], name: "courses_slug_index")

    create constraint(:courses, :courses_capacity_positive,
             check: "((capacity IS NULL) OR (capacity > 0))"
           )

    create constraint(:courses, :courses_confirmed_count_valid,
             check:
               "((confirmed_count >= 0) AND ((capacity IS NULL) OR (confirmed_count <= capacity)))"
           )

    create unique_index(:events, [:slug], name: "events_slug_index")

    create constraint(:events, :events_capacity_positive,
             check: "((capacity IS NULL) OR (capacity > 0))"
           )

    create constraint(:events, :events_confirmed_count_valid,
             check:
               "((confirmed_count >= 0) AND ((capacity IS NULL) OR (confirmed_count <= capacity)))"
           )

    create unique_index(:workflow_step_roles, [:workspace_id, :step_id, :role_id],
             name: "workflow_step_roles_unique_step_role_index"
           )

    create unique_index(:invite_batches, [:invite_code],
             name: "invite_batches_unique_invite_code_index"
           )

    create constraint(:invite_batches, :invite_batches_exactly_one_target,
             check: "((event_id IS NOT NULL) <> (course_id IS NOT NULL))"
           )

    create constraint(:invite_batches, :invite_batches_quota_valid,
             check: "((quota > 0) AND (remaining_quota >= 0) AND (remaining_quota <= quota))"
           )

    create unique_index(:learning_records, [:course_id, :user_id, :issue_id, :item_id],
             name: "learning_records_unique_key_index"
           )

    create index(:learning_records, [:user_id], name: "learning_records_user_id_index")
    create index(:learning_records, [:workspace_id], name: "learning_records_workspace_id_index")

    create index(:speaker_invitations, [:event_id], name: "speaker_invitations_event_id_index")

    create unique_index(:speaker_invitations, [:event_id, :speaker_email],
             name: "speaker_invitations_unique_event_email_index",
             where:
               "((speaker_email IS NOT NULL) AND (status = ANY (ARRAY['invited'::text, 'accepted'::text])))"
           )

    create unique_index(:speaker_invitations, [:token_hash],
             name: "speaker_invitations_unique_token_hash_index"
           )

    create index(:speaker_invitations, [:workspace_id],
             name: "speaker_invitations_workspace_id_index"
           )

    create index(:sponsorships, [:event_id, :status], name: "sponsorships_event_id_status_index")

    create index(:sponsorships, [:sponsor_user_id, :status],
             name: "sponsorships_sponsor_user_id_status_index"
           )

    create unique_index(:sponsorships, [:level, :event_id, :sponsor_user_id],
             name: "sponsorships_unique_event_sponsor_index",
             where:
               "((level = 'event'::text) AND (status = ANY (ARRAY['pending'::text, 'active'::text])))"
           )

    create unique_index(:sponsorships, [:level, :workspace_id, :sponsor_user_id],
             name: "sponsorships_unique_workspace_sponsor_index",
             where:
               "((level = 'workspace'::text) AND (status = ANY (ARRAY['pending'::text, 'active'::text])))"
           )

    create index(:sponsorships, [:workspace_id, :status, :approval_deadline],
             name: "sponsorships_workspace_id_status_approval_deadline_index"
           )

    create constraint(:sponsorships, :sponsorships_level_target_consistency,
             check: "((level = 'event'::text) = (event_id IS NOT NULL))"
           )

    create unique_index(:enrollments, [:course_id, :user_id],
             name: "enrollments_unique_course_user_index",
             where:
               "((course_id IS NOT NULL) AND (status = ANY (ARRAY['pending'::text, 'payment_pending'::text, 'confirmed'::text])))"
           )

    create unique_index(:enrollments, [:event_id, :user_id],
             name: "enrollments_unique_event_user_index",
             where:
               "((event_id IS NOT NULL) AND (status = ANY (ARRAY['pending'::text, 'payment_pending'::text, 'confirmed'::text])))"
           )

    create index(:enrollments, [:workspace_id, :status, :approval_deadline],
             name: "enrollments_workspace_id_status_approval_deadline_index"
           )

    create constraint(:enrollments, :enrollments_exactly_one_target,
             check: "((event_id IS NOT NULL) <> (course_id IS NOT NULL))"
           )

    create index(:sponsorship_deliveries, [:sponsorship_id, :fulfilled_at],
             name: "sponsorship_deliveries_sponsorship_id_fulfilled_at_index"
           )

    create index(:payments_orders, [:status, :expire_at],
             name: "payments_orders_status_expire_at_index"
           )

    create unique_index(:payments_orders, [:enrollment_id],
             name: "payments_orders_unique_active_order_index",
             where:
               "(status = ANY (ARRAY['pending'::text, 'paid'::text, 'refunding'::text, 'refund_failed'::text]))"
           )

    create unique_index(:payments_orders, [:out_trade_no],
             name: "payments_orders_unique_out_trade_no_index"
           )

    create index(:payments_orders, [:workspace_id, :status],
             name: "payments_orders_workspace_id_status_index"
           )
  end

  def down do
    drop table(:payments_orders)
    drop table(:sponsorship_deliveries)
    drop table(:enrollments)
    drop table(:sponsorships)
    drop table(:speaker_invitations)
    drop table(:learning_records)
    drop table(:invite_batches)
    drop table(:workflow_step_roles)
    drop table(:events)
    drop table(:courses)
    drop table(:workflow_steps)
    drop table(:workflow_runs)
    drop table(:miniprogram_codes)
    drop table(:membership_roles)
    drop table(:workspace_memberships)
    drop table(:workspace_applications)
    drop table(:workflow_definitions)
    drop table(:user_identities)
    drop table(:signal_idempotency)
    drop table(:curriculum_outputs)
    drop table(:portfolio_items)
    drop table(:mp_notification_consents)
    drop table(:join_requests)
    drop table(:invitations)
    drop table(:workspaces)
    drop table(:workspace_profiles)
    drop table(:wechat_login_tickets)
    drop table(:users)
    drop table(:tokens)
    drop table(:signal_logs)
    drop table(:roles)
    drop table(:reconciliation_findings)
    drop table(:phone_verification_codes)
    drop table(:payments_webhook_events)
    drop table(:miniprogram_share_schemes)
    drop table(:miniprogram_code_daily_quotas)
    drop table(:mcp_tool_call_logs)
    drop table(:mcp_tokens)
    drop table(:mcp_pending_operations)
    drop table(:jido_thread_meta)
    drop table(:jido_thread_entries)
    drop table(:jido_checkpoints)
    drop table(:admin_action_logs)
    execute "DROP TYPE phone_verification_purpose"
  end
end
