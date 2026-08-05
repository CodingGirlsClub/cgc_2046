defmodule Cgc2046.Repo.Migrations.AddJoinRequests do
  @moduledoc """
  Creates join_requests table for JoinRequest resource（#30）。

  幂等模式：复刻 20260801084116_add_roles_memberships.exs 的
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
    if table_exists?(:join_requests) do
      # 清理旧 schema 遗留列（requested_role_ids/decided_by/decided_at 是旧版字段）
      if column_exists?(:join_requests, :requested_role_ids) do
        alter table(:join_requests) do
          remove :requested_role_ids
        end
      end

      if column_exists?(:join_requests, :decided_by) do
        alter table(:join_requests) do
          remove :decided_by
        end
      end

      if column_exists?(:join_requests, :decided_at) do
        alter table(:join_requests) do
          remove :decided_at
        end
      end

      # 补缺失列（幂等）
      unless column_exists?(:join_requests, :message) do
        alter table(:join_requests) do
          add :message, :text
        end
      end

      unless column_exists?(:join_requests, :approved_by) do
        alter table(:join_requests) do
          add :approved_by, :uuid
        end
      end

      unless column_exists?(:join_requests, :approved_at) do
        alter table(:join_requests) do
          add :approved_at, :utc_datetime
        end
      end

      unless column_exists?(:join_requests, :rejection_reason) do
        alter table(:join_requests) do
          add :rejection_reason, :text
        end
      end

      unless column_exists?(:join_requests, :approval_deadline) do
        alter table(:join_requests) do
          add :approval_deadline, :utc_datetime
        end
      end

      unless column_exists?(:join_requests, :expired_at) do
        alter table(:join_requests) do
          add :expired_at, :utc_datetime
        end
      end

      # 索引幂等
      unless index_exists?(
               :join_requests,
               "join_requests_unique_pending_join_request_per_ws_user_index"
             ) do
        create unique_index(:join_requests, [:workspace_id, :user_id],
                 name: "join_requests_unique_pending_join_request_per_ws_user_index",
                 where: "status = 'pending'"
               )
      end
    else
      create table(:join_requests, primary_key: false) do
        add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

        add :workspace_id,
            references(:workspaces,
              column: :id,
              name: "join_requests_workspace_id_fkey",
              type: :uuid,
              prefix: "public"
            ),
            null: false

        add :user_id,
            references(:users,
              column: :id,
              name: "join_requests_user_id_fkey",
              type: :uuid,
              prefix: "public"
            ),
            null: false

        add :status, :text, null: false, default: "pending"
        add :message, :text
        add :approved_by, :uuid
        add :approved_at, :utc_datetime
        add :rejection_reason, :text
        add :approval_deadline, :utc_datetime
        add :expired_at, :utc_datetime

        add :inserted_at, :utc_datetime_usec,
          null: false,
          default: fragment("(now() AT TIME ZONE 'utc')")

        add :updated_at, :utc_datetime_usec,
          null: false,
          default: fragment("(now() AT TIME ZONE 'utc')")
      end

      create unique_index(:join_requests, [:workspace_id, :user_id],
               name: "join_requests_unique_pending_join_request_per_ws_user_index",
               where: "status = 'pending'"
             )
    end
  end

  def down do
    drop_if_exists unique_index(:join_requests, [:workspace_id, :user_id],
                     name: "join_requests_unique_pending_join_request_per_ws_user_index"
                   )

    drop_if_exists table(:join_requests)
  end
end
