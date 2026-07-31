defmodule Cgc2046Web.AgentsController do
  @moduledoc """
  Agent 相关 REST 端点(T05,spec §4 权限矩阵):
  - `POST /api/v1/workspaces/:workspace_id/agents`:创建 Agent
    (个人=任何成员,owner 自动为 actor;公共=`agent:public:create` Owner/Admin/Tutor)
  - `PATCH /api/v1/workspaces/:workspace_id/agents/:id`:编辑
    (个人=仅 owner;公共=`agent:public:edit`)
  - `DELETE /api/v1/workspaces/:workspace_id/agents/:id`:删除
    (个人=仅 owner;公共=`agent:public:delete` Owner/Admin)

  授权在 Agent 资源 policy + 写 action `Rbac.ensure!`,控制器只翻译状态码。
  """

  use Cgc2046Web, :controller

  alias Cgc2046.Workspaces.Agent

  import Cgc2046Web.ApiHelpers

  def create(conn, params) do
    attrs = pick_attrs(params, ["name", "type"])

    result =
      Ash.create(Agent, attrs,
        actor: actor(conn),
        tenant: tenant(conn)
      )

    handle_ash_result(conn, result, fn agent ->
      conn
      |> put_status(201)
      |> json(%{agent: json_record(agent, [:id, :name, :type, :owner_id, :workspace_id, :inserted_at])})
    end)
  end

  def update(conn, params) do
    attrs = pick_attrs(params, ["name"])

    case fetch_agent(conn) do
      {:ok, agent} ->
        result =
          Ash.update(agent, attrs,
            actor: actor(conn),
            tenant: tenant(conn)
          )

        handle_ash_result(conn, result, fn updated ->
          json(conn, %{agent: json_record(updated, [:id, :name, :type, :owner_id, :workspace_id, :updated_at])})
        end)

      :error ->
        send_not_found(conn)
    end
  end

  def destroy(conn, _params) do
    case fetch_agent(conn) do
      {:ok, agent} ->
        result =
          Ash.destroy(agent,
            actor: actor(conn),
            tenant: tenant(conn)
          )

        handle_ash_result(conn, result, fn _deleted ->
          send_resp(conn, 204, "")
        end)

      :error ->
        send_not_found(conn)
    end
  end

  defp fetch_agent(conn) do
    case Ash.get(Agent, conn.path_params["id"], actor: actor(conn), tenant: tenant(conn)) do
      {:ok, agent} -> {:ok, agent}
      {:error, _} -> :error
    end
  end
end
