defmodule Cgc2046.Mcp.Tools.GetWorkspaceContext do
  @moduledoc """
  读取目标 workspace 的基本信息 + 调用者在该 workspace 的角色（D7 读类）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "get_workspace_context", fn actor, workspace_id, _params ->
        with {:ok, workspace} <- fetch_workspace(workspace_id) do
          roles = MembershipContext.role_names(actor, workspace_id)

          {:ok,
           %{
             workspace_id: workspace.id,
             name: workspace.name,
             slug: workspace.slug,
             join_policy: to_string(workspace.join_policy),
             my_roles: Enum.map(roles, &to_string/1)
           }}
        end
      end)

    to_response(result, frame)
  end

  defp fetch_workspace(workspace_id) do
    case Cgc2046.Accounts.Workspace
         |> Ash.Query.for_read(:get_by_id, %{id: workspace_id})
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, "workspace not found: #{workspace_id}"}
      {:ok, workspace} -> {:ok, workspace}
      {:error, _} -> {:error, "failed to load workspace"}
    end
  end

  defp to_response(result, frame), do: Cgc2046.Mcp.Tools.Response.to_response(result, frame)
end
