defmodule Cgc2046.Repo.Migrations.CreateLlmGatewayTables do
  @moduledoc """
  Phase 1 LLM Gateway 账本地基：工作台算力池字段、个人钱包、工作台批量
  派发留痕、FIFO 额度批次与双成本用量账本。

  新表/新列；`workspaces.credit_pool_mc` 的 CHECK 先以 NOT VALID 上线，
  VALIDATE 在后续独立迁移完成（#634 三段式）。
  """
  use Ecto.Migration

  def up do
    alter table(:workspaces) do
      add :credit_pool_mc, :bigint, null: false, default: 0
    end

    execute("""
    ALTER TABLE workspaces
      ADD CONSTRAINT workspaces_credit_pool_mc_nonnegative
      CHECK (credit_pool_mc >= 0) NOT VALID
    """)

    create table(:llm_wallets, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :cached_balance_mc, :bigint, null: false, default: 0
      add :held_mc, :bigint, null: false, default: 0
      add :max_concurrent_streams, :bigint, null: false, default: 3
      add :status, :text, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_wallets, [:user_id], name: "llm_wallets_unique_user_wallet_index")

    create constraint(:llm_wallets, :llm_wallets_balance_nonnegative,
             check: "cached_balance_mc >= 0"
           )

    create constraint(:llm_wallets, :llm_wallets_held_within_balance,
             check: "held_mc >= 0 AND held_mc <= cached_balance_mc"
           )

    create table(:llm_workspace_grant_batches, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :restrict), null: false
      add :actor_user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :per_member_mc, :bigint, null: false
      add :member_count, :bigint, null: false
      add :total_granted_mc, :bigint, null: false
      add :expires_at, :utc_datetime_usec
      add :idempotency_key, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:llm_workspace_grant_batches, [:workspace_id, :idempotency_key],
             name: "llm_workspace_grant_batches_unique_workspace_idempotency_index"
           )

    create constraint(:llm_workspace_grant_batches, :llm_ws_batches_amounts_positive,
             check: "per_member_mc > 0 AND member_count > 0 AND total_granted_mc > 0"
           )

    create table(:llm_credit_grants, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :wallet_id, references(:llm_wallets, type: :uuid, on_delete: :restrict), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :source_type, :text, null: false
      add :payment_order_id, references(:payments_orders, type: :uuid, on_delete: :restrict)

      add :workspace_batch_id,
          references(:llm_workspace_grant_batches, type: :uuid, on_delete: :restrict)

      add :sponsor_workspace_id, references(:workspaces, type: :uuid, on_delete: :restrict)
      add :granted_by_user_id, references(:users, type: :uuid, on_delete: :restrict)
      add :initial_mc, :bigint, null: false
      add :remaining_mc, :bigint, null: false
      add :expires_at, :utc_datetime_usec
      add :status, :text, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_credit_grants, [:payment_order_id],
             where: "payment_order_id IS NOT NULL",
             name: "llm_credit_grants_unique_payment_order_index"
           )

    create unique_index(:llm_credit_grants, [:workspace_batch_id, :user_id],
             where: "workspace_batch_id IS NOT NULL",
             name: "llm_credit_grants_unique_batch_user_index"
           )

    create index(:llm_credit_grants, [:wallet_id, :status, :expires_at])

    create constraint(:llm_credit_grants, :llm_credit_grants_remaining_valid,
             check: "initial_mc > 0 AND remaining_mc >= 0 AND remaining_mc <= initial_mc"
           )

    create table(:llm_usage_logs, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :wallet_id, references(:llm_wallets, type: :uuid, on_delete: :restrict), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :session_id, :text
      add :logical_model, :text, null: false
      add :upstream_channel, :text, null: false
      add :upstream_model, :text, null: false
      add :billing_mode, :text, null: false
      add :prompt_cache_hit_tokens, :bigint, null: false, default: 0
      add :prompt_cache_miss_tokens, :bigint, null: false, default: 0
      add :completion_tokens, :bigint, null: false, default: 0
      add :reasoning_tokens, :bigint, null: false, default: 0
      add :charged_mc, :bigint, null: false
      add :upstream_cost_mc, :bigint, null: false
      add :ttfb_ms, :bigint
      add :duration_ms, :bigint

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:llm_usage_logs, [:user_id, :inserted_at])
    create index(:llm_usage_logs, [:inserted_at, :upstream_channel])
  end

  def down do
    drop table(:llm_usage_logs)
    drop table(:llm_credit_grants)
    drop table(:llm_workspace_grant_batches)
    drop table(:llm_wallets)

    execute(
      "ALTER TABLE workspaces DROP CONSTRAINT IF EXISTS workspaces_credit_pool_mc_nonnegative"
    )

    alter table(:workspaces) do
      remove :credit_pool_mc
    end
  end
end
