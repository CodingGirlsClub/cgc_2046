defmodule Cgc2046.Repo.Migrations.CreateUserIdentities do
  @moduledoc """
  小程序平台身份表（Phase 1 身份基座，Q1 UserIdentity：provider/uid/unionid/user_id）。

  唯一约束 (provider, uid)：同一平台账号只绑定一个 User。
  幂等模式复刻 20260804000000_add_invitations.exs（共享 dev DB 多 worktree 约定）。
  """

  use Ecto.Migration

  defp table_exists?(table) do
    repo()
    |> Ecto.Adapters.SQL.query!("SELECT to_regclass('public.#{table}') IS NOT NULL", [])
    |> then(fn result -> result.rows |> hd |> hd end)
  end

  defp index_exists?(table, name) do
    repo()
    |> Ecto.Adapters.SQL.query!(
      "SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND tablename = $1 AND indexname = $2",
      [to_string(table), to_string(name)]
    )
    |> then(fn result -> result.num_rows > 0 end)
  end

  def up do
    unless table_exists?(:user_identities) do
      create table(:user_identities, primary_key: false) do
        add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
        add :provider, :text, null: false
        add :uid, :text, null: false
        add :unionid, :text

        add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false

        add :inserted_at, :utc_datetime_usec,
          null: false,
          default: fragment("(now() AT TIME ZONE 'utc')")

        add :updated_at, :utc_datetime_usec,
          null: false,
          default: fragment("(now() AT TIME ZONE 'utc')")
      end
    end

    # 索引名与 AshPostgres identity 错误映射约定一致：<table>_<identity>_index
    unless index_exists?(:user_identities, "user_identities_unique_provider_uid_index") do
      create unique_index(:user_identities, [:provider, :uid],
               name: "user_identities_unique_provider_uid_index"
             )
    end
  end

  def down do
    drop_if_exists unique_index(:user_identities, [:provider, :uid],
                     name: "user_identities_unique_provider_uid_index"
                   )

    drop_if_exists table(:user_identities)
  end
end
