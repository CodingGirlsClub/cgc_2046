defmodule Cgc2046.Mcp.Tools.AdminListAuditLogs do
  @moduledoc """
  平台治理：审计日志统一读面（role-agent-journeys-v2 S2，R12/R16 的
  MCP 面；**只暴露操作元数据**，R16/AE13）。

  `source` 必选三选一：

  - `tool_calls`：MCP 工具调用审计（谁/工具/结果状态/耗时/归因维度）
  - `pending_operations`：确认流待办（谁/工具/确认状态/时间戳）
  - `admin_actions`：治理操作留痕（谁/动作/目标/结果）

  平台治理审计面只暴露操作元数据，学员证据/回答正文永不进入本工具
  （正文留存的 learning 工具审计在 S8/S10 收窄）：**本工具不读 params/metadata
  列**，只投影 id / actor / 操作名 / 状态 / 耗时 / 归因维度 / 时间戳——
  对 params 列结构性免疫，不依赖查询后的字段裁剪纪律（§B#21）。

  授权 = Wrapper `:platform_admin` 门控族 + 各资源 read policy 的
  platform_admin 放行兜底。按 inserted_at 倒序，封顶 50 条。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.Mcp.{PendingOperation, ToolCallLog}
  alias Cgc2046.Mcp.Wrapper

  @sources ~w(tool_calls pending_operations admin_actions)
  @limit 50

  schema do
    field(:source, {:required, :string},
      description:
        "审计来源：tool_calls | pending_operations | admin_actions（只读操作元数据，无 params/payload）"
    )
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_list_audit_logs", fn actor, _workspace_id, params ->
        source = params["source"] || params[:source]

        with {:ok, source} <- parse_source(source),
             {:ok, rows} <- read_source(source, actor) do
          {:ok, %{source: source, count: length(rows), logs: rows}}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  defp parse_source(source) when source in @sources, do: {:ok, source}

  defp parse_source(_source),
    do: {:error, "invalid source (expected one of #{Enum.join(@sources, "|")})"}

  # 三源同一读取纪律：for_read(:read) + actor 授权（platform_admin policy）+
  # 倒序 + 封顶；投影在 to_row 白名单内，params/metadata 列不进入返回值。
  defp read_source(source, actor) do
    resource = resource_for(source)

    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(@limit)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, records} ->
        {:ok, Enum.map(records, &to_row(source, &1))}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: platform admin required to list audit logs"}

      {:error, _} ->
        {:error, "failed to list audit logs"}
    end
  end

  defp resource_for("tool_calls"), do: ToolCallLog
  defp resource_for("pending_operations"), do: PendingOperation
  defp resource_for("admin_actions"), do: AdminActionLog

  # 元数据白名单（无 params）：error_message 是截断 500 的错误摘要（redact 后），
  # 与 GraphQL admin_tool_call_log 同口径
  defp to_row("tool_calls", log) do
    %{
      id: log.id,
      user_id: log.user_id,
      tool: log.tool,
      result_status: to_string(log.result_status),
      error_message: log.error_message,
      latency_ms: log.latency_ms,
      pending_operation_id: log.pending_operation_id,
      client_name: log.client_name,
      session_id: log.session_id,
      inserted_at: log.inserted_at
    }
  end

  # 元数据白名单（无 params/summary）：状态为库存 status，过期由 expires_at 读时派生
  defp to_row("pending_operations", op) do
    %{
      id: op.id,
      user_id: op.user_id,
      tool: op.tool,
      status: to_string(op.status),
      expires_at: op.expires_at,
      resolved_at: op.resolved_at,
      inserted_at: op.inserted_at
    }
  end

  # 元数据白名单（无 metadata 快照列）
  defp to_row("admin_actions", log) do
    %{
      id: log.id,
      actor_id: log.actor_id,
      action: to_string(log.action),
      target_type: to_string(log.target_type),
      target_id: log.target_id,
      result: to_string(log.result),
      inserted_at: log.inserted_at
    }
  end
end
