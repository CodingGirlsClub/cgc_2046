defmodule Cgc2046.Mcp.Tools.AdminListInitiatives do
  @moduledoc """
  平台管理员专用：列出倡导活动（含 draft），按创建时间倒序，最多 50 条。status 精确过滤，
  search 对 name 或 slug 做包含匹配，两者均可省略。返回 count + initiatives（id / name /
  slug / status / inserted_at），不含规则，详情用 admin_get_initiative。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Initiatives.Initiative
  alias Cgc2046.Mcp.Wrapper
  require Ash.Query

  schema do
    field(:status, :string, description: "draft | open | closed | cancelled")
    field(:search, :string, description: "按名称或 slug 模糊搜索")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_list_initiatives", fn actor, _ws, params ->
        query =
          Initiative
          |> Ash.Query.for_read(:read)
          |> maybe_status(params["status"])
          |> maybe_search(params["search"])
          |> Ash.Query.sort(inserted_at: :desc, id: :desc)
          |> Ash.Query.limit(50)

        case Ash.read(query, actor: actor) do
          {:ok, rows} -> {:ok, %{count: length(rows), initiatives: Enum.map(rows, &summary/1)}}
          {:error, _} -> {:error, "failed to list initiatives"}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  defp maybe_status(query, nil), do: query

  defp maybe_status(query, status),
    do: Ash.Query.filter(query, status == ^String.to_existing_atom(status))

  defp maybe_search(query, nil), do: query
  defp maybe_search(query, ""), do: query

  defp maybe_search(query, search),
    do: Ash.Query.filter(query, contains(name, ^search) or contains(slug, ^search))

  defp summary(row),
    do: %{
      id: row.id,
      name: row.name,
      slug: row.slug,
      status: to_string(row.status),
      inserted_at: row.inserted_at
    }
end
