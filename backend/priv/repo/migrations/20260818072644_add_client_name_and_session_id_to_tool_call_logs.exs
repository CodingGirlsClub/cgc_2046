defmodule Cgc2046.Repo.Migrations.AddClientNameAndSessionIdToToolCallLogs do
  @moduledoc """
  #228：ToolCallLog 补归因维度两列（多宿主 BYO 前置数据资产）。

  - `client_name`：宿主客户端名（initialize clientInfo.name，如 openclacky/omp/opencode/dsh）
  - `session_id`：MCP 会话 id（HTTP 为 Mcp-Session-Id；stdio 恒为 "stdio"）

  两列均 nullable：历史行保持 null 不回填（流水维度不记则历史永久不可回填，
  故只前向记录）；取不到 clientInfo/session 的调用也安全落 null。
  """
  use Ecto.Migration

  def change do
    alter table(:mcp_tool_call_logs) do
      add(:client_name, :text, null: true)
      add(:session_id, :text, null: true)
    end
  end
end
