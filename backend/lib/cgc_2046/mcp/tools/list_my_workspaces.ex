defmodule Cgc2046.Mcp.Tools.ListMyWorkspaces do
  @moduledoc """
  列出 actor 加入的全部工作台及在各工作台的角色（role-agent-journeys-v2 S1，R3）。

  actor 锚定的跨工作台读（不收任何用户参数）：agent 启动后先调本工具让用户
  按名称选定工作上下文，返回的 workspace_id 供后续工具使用——用户永不手填 UUID。

  meta `%{workspace_id: :optional}` 命中 Wrapper `:optional` 分支（跳过
  membership 校验 + 豁免 workspace_id 必填）——刻意为之：本工具无单一
  workspace 可作门，数据面本身即按 actor 收窄
  （`MembershipContext.memberships_of_actor/1`），无越权面，也无须工具层
  二次授权（故不携带 `membership: :deferred` 键）。

  返回 workspaces 按工作台名称排序；roles 为该工作台内角色名的字符串列表
  （多角色并集）。`is_platform_admin` 供客户端决定是否展示平台治理入口。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional}

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Accounts.Policies.PlatformAdmin
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Mcp.Wrapper

  require Ash.Query

  schema do
    %{}
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "list_my_workspaces", fn actor, _workspace_id, _params ->
        memberships = MembershipContext.memberships_of_actor(actor)

        with {:ok, workspaces} <- load_workspaces(memberships) do
          rows =
            memberships
            |> Enum.map(&to_row(&1, workspaces))
            |> Enum.reject(&is_nil/1)
            |> Enum.sort_by(& &1.name)

          {:ok, %{workspaces: rows, is_platform_admin: PlatformAdmin.platform_admin?(actor)}}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # memberships 是跨租户 global 读，workspace 未 preload——按 id 集单独批量读。
  # 非 bang read：DB 失败返结构化错误走 Wrapper 审计，不逃逸（list_public_offerings 同款纪律）。
  defp load_workspaces(memberships) do
    ids = memberships |> Enum.map(& &1.workspace_id) |> Enum.uniq()

    Workspace
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, workspaces} -> {:ok, Map.new(workspaces, &{&1.id, &1})}
      {:error, _} -> {:error, "failed to load workspaces"}
    end
  end

  # 工作台记录缺失（极端：删库残留）的行丢弃，不返回 name/slug 为 nil 的半成品。
  defp to_row(membership, workspaces) do
    case Map.get(workspaces, membership.workspace_id) do
      nil ->
        nil

      workspace ->
        %{
          workspace_id: workspace.id,
          name: workspace.name,
          slug: workspace.slug,
          roles: Enum.map(membership.roles, &to_string(&1.name))
        }
    end
  end
end
