defmodule Cgc2046.Repo.Migrations.CreateLlmWalletHolds do
  @moduledoc """
  Per-request LLM credit holds. `LeaseManager` only protects in-memory stream
  slots; this table makes PostgreSQL holds recoverable when a request process
  is killed or the BEAM restarts before settlement.
  """
  use Ecto.Migration

  def up do
    create table(:llm_wallet_holds, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :wallet_id, references(:llm_wallets, type: :uuid, on_delete: :restrict), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :hold_mc, :bigint, null: false
      add :status, :text, null: false, default: "active"
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:llm_wallet_holds, [:status, :expires_at])
    create index(:llm_wallet_holds, [:wallet_id, :status])

    create constraint(:llm_wallet_holds, :llm_wallet_holds_positive, check: "hold_mc > 0")
  end

  def down do
    drop table(:llm_wallet_holds)
  end
end
