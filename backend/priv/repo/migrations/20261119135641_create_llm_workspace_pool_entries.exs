defmodule Cgc2046.Repo.Migrations.CreateLlmWorkspacePoolEntries do
  @moduledoc """
  Plan 010: append-only ledger for workspace LLM credit pool mutations
  (`order_topup`, `admin_topup`, `batch_grant_debit`, `migration_baseline`).
  """

  use Ecto.Migration

  def up do
    create table(:llm_workspace_pool_entries, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :restrict), null: false
      add :entry_type, :text, null: false
      add :delta_mc, :bigint, null: false

      add :payment_order_id, references(:llm_payment_orders, type: :uuid, on_delete: :restrict),
        null: true

      add :workspace_batch_id,
          references(:llm_workspace_grant_batches, type: :uuid, on_delete: :restrict),
          null: true

      add :actor_user_id, references(:users, type: :uuid, on_delete: :restrict), null: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:llm_workspace_pool_entries, :llm_workspace_pool_entries_type_valid,
             check:
               "entry_type IN ('order_topup', 'admin_topup', 'batch_grant_debit', 'migration_baseline')"
           )

    create constraint(:llm_workspace_pool_entries, :llm_workspace_pool_entries_delta_nonzero,
             check: "delta_mc <> 0"
           )

    create unique_index(:llm_workspace_pool_entries, [:payment_order_id],
             where: "payment_order_id IS NOT NULL",
             name: "llm_workspace_pool_entries_unique_payment_order_index"
           )

    create unique_index(:llm_workspace_pool_entries, [:workspace_batch_id],
             where: "workspace_batch_id IS NOT NULL",
             name: "llm_workspace_pool_entries_unique_batch_index"
           )

    create index(:llm_workspace_pool_entries, [:workspace_id, :inserted_at])

    execute("""
    INSERT INTO llm_workspace_pool_entries (id, workspace_id, entry_type, delta_mc, inserted_at)
    SELECT gen_random_uuid(), id, 'migration_baseline', credit_pool_mc, NOW() AT TIME ZONE 'utc'
    FROM workspaces
    WHERE credit_pool_mc > 0
    """)
  end

  def down do
    drop table(:llm_workspace_pool_entries)
  end
end
