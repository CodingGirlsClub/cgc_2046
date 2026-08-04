defmodule Cgc2046.Repo.Migrations.AddInvitations do
  @moduledoc """
  Creates invitations table for Invitation resource（#31）。

  幂等模式：复刻 20260803000000_add_join_requests.exs 的
  table_exists?/index_exists?/column_exists? 辅助函数。
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

  defp column_exists?(table, column) do
    repo()
    |> Ecto.Adapters.SQL.query!(
      "SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2",
      [to_string(table), to_string(column)]
    )
    |> then(fn result -> result.num_rows > 0 end)
  end

  def up do
    if table_exists?(:invitations) do
      # 补缺失列（幂等）
      unless column_exists?(:invitations, :token_hash) do
        alter table(:invitations) do
          add :token_hash, :text, null: false
        end
      end

      unless column_exists?(:invitations, :plain_token) do
        alter table(:invitations) do
          add :plain_token, :text
        end
      end

      unless column_exists?(:invitations, :inviter_id) do
        alter table(:invitations) do
          add :inviter_id, :uuid, null: false
        end
      end

      unless column_exists?(:invitations, :target_email) do
        alter table(:invitations) do
          add :target_email, :text
        end
      end

      unless column_exists?(:invitations, :preauthorized_role_names) do
        alter table(:invitations) do
          add :preauthorized_role_names, {:array, :text}
        end
      end

      unless column_exists?(:invitations, :expires_at) do
        alter table(:invitations) do
          add :expires_at, :utc_datetime
        end
      end

      unless column_exists?(:invitations, :status) do
        alter table(:invitations) do
          add :status, :text, null: false, default: "active"
        end
      end

      unless column_exists?(:invitations, :accepted_by) do
        alter table(:invitations) do
          add :accepted_by, :uuid
        end
      end

      unless column_exists?(:invitations, :accepted_at) do
        alter table(:invitations) do
          add :accepted_at, :utc_datetime
        end
      end

      # 索引幂等
      unless index_exists?(:invitations, "invitations_unique_token_hash_index") do
        create unique_index(:invitations, [:token_hash],
                 name: "invitations_unique_token_hash_index"
               )
      end
    else
      create table(:invitations, primary_key: false) do
        add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

        add :workspace_id,
            references(:workspaces,
              column: :id,
              name: "invitations_workspace_id_fkey",
              type: :uuid,
              prefix: "public"
            ),
            null: false

        add :token_hash, :text, null: false
        add :plain_token, :text
        add :inviter_id, :uuid, null: false
        add :target_email, :text
        add :preauthorized_role_names, {:array, :text}
        add :expires_at, :utc_datetime
        add :status, :text, null: false, default: "active"
        add :accepted_by, :uuid
        add :accepted_at, :utc_datetime

        add :inserted_at, :utc_datetime_usec,
          null: false,
          default: fragment("(now() AT TIME ZONE 'utc')")

        add :updated_at, :utc_datetime_usec,
          null: false,
          default: fragment("(now() AT TIME ZONE 'utc')")
      end

      create unique_index(:invitations, [:token_hash],
               name: "invitations_unique_token_hash_index"
             )
    end
  end

  def down do
    drop_if_exists unique_index(:invitations, [:token_hash],
                     name: "invitations_unique_token_hash_index"
                   )

    drop_if_exists table(:invitations)
  end
end
