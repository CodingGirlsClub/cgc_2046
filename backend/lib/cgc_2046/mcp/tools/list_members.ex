defmodule Cgc2046.Mcp.Tools.ListMembers do
  @moduledoc """
  列出目标 workspace 的成员及角色（D7 读类）。
  走 `WorkspaceMembership` read policy（成员见自己、Owner/Admin 见全部），tenant 过滤由
  调用处显式带 `tenant: workspace_id`（与 GraphQL workspaceMembers 同一授权面）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "list_members", fn actor, workspace_id, _params ->
        # read!（bang）会逃逸 Wrapper 的审计落库；用 read/2 + 错误分类保证 Forbidden 也落 ToolCallLog
        case Cgc2046.Accounts.WorkspaceMembership
             |> Ash.Query.load(:roles)
             |> Ash.read(actor: actor, tenant: workspace_id) do
          {:ok, members} ->
            {:ok,
             %{
               workspace_id: workspace_id,
               members:
                 Enum.map(members, fn m ->
                   %{
                     membership_id: m.id,
                     user_id: m.user_id,
                     roles: Enum.map(m.roles, &to_string(&1.name))
                   }
                 end)
             }}

          {:error, %Ash.Error.Forbidden{}} ->
            {:error, "forbidden: not allowed to list members of workspace #{workspace_id}"}

          {:error, _} ->
            {:error, "failed to list members"}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end
end
