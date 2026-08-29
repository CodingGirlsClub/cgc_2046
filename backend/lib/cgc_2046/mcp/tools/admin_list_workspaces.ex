defmodule Cgc2046.Mcp.Tools.AdminListWorkspaces do
  @moduledoc """
  平台治理：工作台列表（role-agent-journeys-v2 S2，R12–R16 的 MCP 面）。

  数据面同 GraphQL `listWorkspaces`：search 匹配 name / slug，预载
  member_count 计算字段，按 inserted_at 倒序，封顶 50 条。授权 =
  Wrapper `:platform_admin` 门控族 + Workspace read policy 的
  platform_admin 放行兜底（含 invite_only）。

  返回紧凑工作台概要（id / name / slug / join_policy /
  sponsorship_enabled / member_count / inserted_at）。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Mcp.Wrapper

  require Ash.Query

  @limit 50

  schema do
    field(:search, :string, description: "按工作台名称 / slug 模糊过滤（可选）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_list_workspaces", fn actor, _workspace_id, params ->
        search = params["search"] || params[:search]

        Workspace
        |> Ash.Query.for_read(:read)
        |> maybe_search(search)
        |> Ash.Query.load(:member_count)
        |> Ash.Query.sort(inserted_at: :desc, id: :desc)
        |> Ash.Query.limit(@limit)
        |> Ash.read(actor: actor)
        |> case do
          {:ok, workspaces} ->
            {:ok, %{count: length(workspaces), workspaces: Enum.map(workspaces, &to_row/1)}}

          {:error, %Ash.Error.Forbidden{}} ->
            {:error, "forbidden: platform admin required to list workspaces"}

          {:error, _} ->
            {:error, "failed to list workspaces"}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 与 GraphQL maybe_workspace_search 同形：name / slug contains OR
  defp maybe_search(query, nil), do: query
  defp maybe_search(query, ""), do: query

  defp maybe_search(query, search) do
    Ash.Query.filter(query, contains(name, ^search) or contains(slug, ^search))
  end

  defp to_row(workspace) do
    %{
      id: workspace.id,
      name: workspace.name,
      slug: workspace.slug,
      join_policy: to_string(workspace.join_policy),
      sponsorship_enabled: workspace.sponsorship_enabled,
      member_count: workspace.member_count,
      inserted_at: workspace.inserted_at
    }
  end
end
