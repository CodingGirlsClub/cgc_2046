defmodule Cgc2046.Repo.Migrations.AddLlmGatewayOpsIndexes do
  @moduledoc """
  Plan 007: concurrent operational indexes for LLM Gateway credit expiry scans,
  workspace grant batch history queries, and date-scoped payment reconciliation.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists index(:llm_credit_grants, [:expires_at],
                           where: "status = 'active' AND expires_at IS NOT NULL",
                           name: :llm_credit_grants_active_expires_at_index,
                           concurrently: true
                         )

    create_if_not_exists index(:llm_workspace_grant_batches, [:workspace_id, :inserted_at],
                           name: :llm_workspace_grant_batches_workspace_inserted_at_index,
                           concurrently: true
                         )

    create_if_not_exists index(:llm_payment_orders, [:status, :paid_at],
                           where: "status = 'paid'",
                           name: :llm_payment_orders_paid_at_index,
                           concurrently: true
                         )
  end

  def down do
    drop_if_exists index(:llm_payment_orders, [:status, :paid_at],
                     name: :llm_payment_orders_paid_at_index,
                     concurrently: true
                   )

    drop_if_exists index(:llm_workspace_grant_batches, [:workspace_id, :inserted_at],
                     name: :llm_workspace_grant_batches_workspace_inserted_at_index,
                     concurrently: true
                   )

    drop_if_exists index(:llm_credit_grants, [:expires_at],
                     name: :llm_credit_grants_active_expires_at_index,
                     concurrently: true
                   )
  end
end
