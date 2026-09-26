defmodule Cgc2046.Mcp.Tools.AdminListUsers do
  @moduledoc """
  平台治理：用户列表（role-agent-journeys-v2 S2，R12–R16 的 MCP 面）。

  数据面同 GraphQL `listUsers`：search 匹配 email / display_name，按
  inserted_at 倒序，封顶 50 条。授权 = Wrapper `:platform_admin` 门控族
  （`is_platform_admin` 全局标记，fail-closed）+ User read policy 的
  platform_admin 放行兜底。

  返回紧凑用户概要（id / email / display_name / is_platform_admin /
  inserted_at）；email 可为 nil（小程序手机号用户）。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Accounts.User
  alias Cgc2046.AdminList
  alias Cgc2046.Mcp.Wrapper

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    平台管理员专用：列出用户，search 按邮箱或显示名模糊匹配（可选）。按注册时间倒序，最多 50 条。
    返回 id / email / display_name / is_platform_admin / inserted_at；小程序手机号注册的用户 email
    可能为空。
    """
  end

  schema do
    field(:search, :string, description: "按邮箱 / 显示名模糊过滤（可选）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_list_users", fn actor, _workspace_id, params ->
        search = params["search"]

        User
        |> Ash.Query.for_read(:read)
        |> AdminList.maybe_user_search(search)
        |> AdminList.recent()
        |> Ash.read(actor: actor)
        |> case do
          {:ok, users} ->
            {:ok, %{count: length(users), users: Enum.map(users, &to_row/1)}}

          {:error, %Ash.Error.Forbidden{}} ->
            {:error, "forbidden: platform admin required to list users"}

          {:error, _} ->
            {:error, "failed to list users"}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  defp to_row(user) do
    %{
      id: user.id,
      email: user.email && to_string(user.email),
      display_name: user.display_name,
      is_platform_admin: user.is_platform_admin,
      inserted_at: user.inserted_at
    }
  end
end
