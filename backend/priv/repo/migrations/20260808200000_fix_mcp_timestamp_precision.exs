defmodule Cgc2046.Repo.Migrations.FixMcpTimestampPrecision do
  @moduledoc """
  修正 mcp 三表时间戳列精度（review 修复，替代对已应用迁移 20260808120000 的直接编辑）。

  只改与 Ash 资源声明不一致的 5 列：`create_timestamp`/`update_timestamp` 宏声明的类型是
  `Ash.Type.UtcDatetimeUsec`（微秒），原迁移手写成了 `:utc_datetime`（秒）。
  秒精度会让 `myMcpTokens` 的 `sort(inserted_at: :desc)` 在同秒多次签发时次序不定。

  其余 4 列（last_used_at/revoked_at/expires_at/resolved_at）资源声明即 `:utc_datetime`，
  与资源保持一致，不动。
  """
  use Ecto.Migration

  def change do
    alter table(:mcp_tokens) do
      modify(:inserted_at, :utc_datetime_usec, null: false)
      modify(:updated_at, :utc_datetime_usec, null: false)
    end

    alter table(:mcp_tool_call_logs) do
      modify(:inserted_at, :utc_datetime_usec, null: false)
    end

    alter table(:mcp_pending_operations) do
      modify(:inserted_at, :utc_datetime_usec, null: false)
      modify(:updated_at, :utc_datetime_usec, null: false)
    end
  end
end
