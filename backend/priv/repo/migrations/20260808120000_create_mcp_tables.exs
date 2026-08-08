defmodule Cgc2046.Repo.Migrations.CreateMcpTables do
  @moduledoc """
  切片 D（#42）：MCP 域三张表——连接 token / 工具调用审计 / 确认流 pending。
  """
  use Ecto.Migration

  def change do
    create table(:mcp_tokens, primary_key: false) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:token_hash, :text, null: false)
      add(:name, :text, null: false)
      add(:user_id, :uuid, null: false)
      add(:last_used_at, :utc_datetime)
      add(:revoked_at, :utc_datetime)
      add(:inserted_at, :utc_datetime, null: false)
      add(:updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:mcp_tokens, [:token_hash]))
    create(index(:mcp_tokens, [:user_id]))

    create table(:mcp_tool_call_logs, primary_key: false) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:user_id, :uuid, null: false)
      add(:tool, :text, null: false)
      add(:params, :map, null: false)
      add(:result_status, :text, null: false)
      add(:error_message, :text)
      add(:latency_ms, :bigint)
      add(:pending_operation_id, :uuid)
      add(:inserted_at, :utc_datetime, null: false)
    end

    create(index(:mcp_tool_call_logs, [:user_id]))
    create(index(:mcp_tool_call_logs, [:tool]))

    create table(:mcp_pending_operations, primary_key: false) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:user_id, :uuid, null: false)
      add(:tool, :text, null: false)
      add(:params, :map, null: false)
      add(:summary, :text, null: false)
      add(:status, :text, null: false)
      add(:expires_at, :utc_datetime, null: false)
      add(:resolved_at, :utc_datetime)
      add(:inserted_at, :utc_datetime, null: false)
      add(:updated_at, :utc_datetime, null: false)
    end

    create(index(:mcp_pending_operations, [:user_id]))
  end
end
