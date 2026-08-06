defmodule Cgc2046.Repo.Migrations.SliceCJidoStorage do
  @moduledoc """
  Jido.Storage Postgres 适配器的表（阶段 4 #37）。

  checkpoint 与 thread 数据用 `:erlang.term_to_binary/1` 编码存 `bytea` 列——
  workflow struct 含匿名闭包（非 external function），JSON 无法编码；
  同 BEAM 内 `term_to_binary`/`binary_to_term` round-trip 安全（闭包编码为模块引用）。

  表结构对应 `Jido.Storage.ETS` 的三表形态：
  - `jido_checkpoints`：checkpoint 数据（key_bytea 主键）
  - `jido_thread_entries`：thread 条目（thread_id + seq 复合主键）
  - `jido_thread_meta`：thread 元数据 + 乐观并发 rev（thread_id 主键）
  """

  use Ecto.Migration

  def up do
    create table(:jido_checkpoints, primary_key: false) do
      add :key_bytea, :bytea, null: false, primary_key: true
      add :data_bytea, :bytea, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create table(:jido_thread_entries, primary_key: false) do
      add :thread_id, :string, null: false, primary_key: true
      add :seq, :bigint, null: false, primary_key: true
      add :entry_bytea, :bytea, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:jido_thread_entries, [:thread_id])

    create table(:jido_thread_meta, primary_key: false) do
      add :thread_id, :string, null: false, primary_key: true
      add :rev, :bigint, null: false, default: 0
      add :metadata_bytea, :bytea

      add :created_at, :bigint
      add :updated_at, :bigint
    end
  end

  def down do
    drop table(:jido_thread_meta)
    drop index(:jido_thread_entries, [:thread_id])
    drop table(:jido_thread_entries)
    drop table(:jido_checkpoints)
  end
end
