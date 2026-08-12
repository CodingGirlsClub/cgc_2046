defmodule Cgc2046.Repo.Migrations.CreateSignalIdempotency do
  use Ecto.Migration

  def change do
    # POC-2 G2 B3 硬约束：幂等键去重表承载于 Postgres 唯一约束，
    # 不得由 action 进程自建 ETS（进程退出即失效）。
    # 报名/赞助/邀请/教研四份 workflow 共用本表。
    create table(:signal_idempotency, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :delete_all)
      add :signal_type, :text, null: false
      add :idempotency_key, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:signal_idempotency, [:signal_type, :idempotency_key],
             name: "signal_idempotency_unique_signal_key_index"
           )

    create index(:signal_idempotency, [:workspace_id])
    create index(:signal_idempotency, [:inserted_at])
  end
end
