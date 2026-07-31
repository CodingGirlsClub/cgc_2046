defmodule Cgc2046Web.MeController do
  @moduledoc """
  `GET /api/v1/me`:返回当前认证主体信息(spec §5,渲染"我能做什么")。

  - **JWT 会话**(网站用户):返回 `user`,workspace 上下文由前端工作台选择,
    本端点保持占位(workspace_id/roles/scopes 为空,T02 契约不变)。
  - **ApiToken 机器凭证**(OpenClacky 扩展):返回 token 绑定的 workspace、
    能力域 scopes 与**可执行 Step 列表**("我能做什么",验收点 5)。

  可执行 Step 判定:用户在该 workspace 的角色集合 ∩ Step 允许角色集合
  交集非空(`Rbac.role_intersection?/3`,spec §3 授权第 3 环)。
  """

  use Cgc2046Web, :controller

  import Ash.Query, only: [filter: 2]

  alias Cgc2046.Rbac
  alias Cgc2046.Workspaces.{ApiToken, Role, Step}

  def show(conn, _params) do
    user = conn.assigns[:current_user]

    case conn.assigns[:api_token] do
      %ApiToken{} = api_token ->
        json(conn, me_with_api_token(user, api_token))

      _ ->
        json(conn, %{
          user: %{id: user.id, email: user.email},
          workspace_id: nil,
          roles: [],
          scopes: [],
          executable_steps: []
        })
    end
  end

  defp me_with_api_token(user, api_token) do
    workspace_id = api_token.workspace_id
    role_names = role_names(user, workspace_id)

    %{
      user: %{id: user.id, email: user.email},
      workspace_id: workspace_id,
      roles: role_names,
      scopes: api_token.scopes,
      executable_steps: executable_steps(user, workspace_id)
    }
  end

  defp role_names(user, workspace_id) do
    role_ids = MapSet.to_list(Rbac.actor_role_ids(user, workspace_id))

    if role_ids == [] do
      []
    else
      Role
      |> filter(id in ^role_ids)
      |> Ash.Query.select([:name])
      |> Ash.read!(tenant: workspace_id, authorize?: false)
      |> Enum.map(& &1.name)
    end
  end

  defp executable_steps(user, workspace_id) do
    Step
    |> Ash.Query.load(:roles)
    |> Ash.Query.load(:workflow)
    |> Ash.read!(tenant: workspace_id, authorize?: false)
    |> Enum.filter(fn step ->
      # T08:归档 Workflow 的 Step 不可执行(验收点 6)
      step.workflow.status != "archived" and
        Rbac.role_intersection?(user, workspace_id, Enum.map(step.roles, & &1.id))
    end)
    |> Enum.map(fn step ->
      %{
        id: step.id,
        title: step.title,
        position: step.position,
        type: step.type,
        agent_hint: step.agent_hint
      }
    end)
  end
end
