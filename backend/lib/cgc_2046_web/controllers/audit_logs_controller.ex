defmodule Cgc2046Web.AuditLogsController do
  @moduledoc """
  审计查询 REST 端点(T05,spec §11 读隔离):
  - `GET /api/v1/audit_logs`:查自己的审计记录(任何认证用户)
  - `GET /api/v1/workspaces/:workspace_id/audit_logs`:查 workspace 的审计
    (需 `audit:view`,Owner/Admin)

  读隔离双重保障:控制器显式校验 `audit:view` + AuditLog 资源 policy 行级 filter
  (`AuditLogVisible`:自己的 或 拥有 audit:view 的 workspace 的)。
  """

  use Cgc2046Web, :controller

  require Ash.Query

  alias Cgc2046.Audit.AuditLog

  import Cgc2046Web.ApiHelpers

  def index(conn, _params) do
    actor = actor(conn)

    query =
      AuditLog
      |> Ash.Query.filter(actor_id == ^actor.id)

    read_and_reply(conn, query)
  end

  def workspace_index(conn, _params) do
    actor = actor(conn)
    workspace_id = tenant(conn)

    if workspace_id && Cgc2046.Rbac.can?(actor, "audit:view", tenant: workspace_id) do
      query =
        AuditLog
        |> Ash.Query.filter(workspace_id == ^workspace_id)

      read_and_reply(conn, query)
    else
      send_error(conn, 403, "Forbidden")
    end
  end

  defp read_and_reply(conn, query) do
    case Ash.read(query, actor: actor(conn), domain: Cgc2046.GlobalApi) do
      {:ok, logs} ->
        json(conn, %{audit_logs: Enum.map(logs, &audit_log_json/1)})

      {:error, %Ash.Error.Forbidden{}} ->
        send_error(conn, 403, "Forbidden")

      {:error, error} ->
        send_error(conn, 400, Exception.message(error))
    end
  end

  defp audit_log_json(log) do
    %{
      id: log.id,
      actor_id: log.actor_id,
      client: log.client,
      action: log.action,
      resource: log.resource,
      workspace_id: log.workspace_id,
      ip: log.ip,
      result: log.result,
      created_at: log.inserted_at
    }
  end
end
