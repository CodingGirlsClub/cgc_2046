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

  @valid_statuses ~w(draft open closed cancelled)

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_list_initiatives", fn actor, _ws, params ->
        with {:ok, query} <- status_filter(params["status"]) do
          query =
            query
            |> maybe_search(params["search"])
            |> Ash.Query.sort(inserted_at: :desc, id: :desc)
            |> Ash.Query.limit(50)

          case Ash.read(query, actor: actor) do
            {:ok, rows} -> {:ok, %{count: length(rows), initiatives: Enum.map(rows, &summary/1)}}
            {:error, _} -> {:error, "failed to list initiatives"}
          end
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 白名单校验在入口做：未知值报明确错误，而不是 String.to_existing_atom 抛
  # ArgumentError 打崩调用
  defp status_filter(nil),
    do: {:ok, Initiative |> Ash.Query.for_read(:read)}

  defp status_filter(status) when status in @valid_statuses,
    do:
      {:ok,
       Initiative
       |> Ash.Query.for_read(:read)
       |> Ash.Query.filter(status == ^String.to_existing_atom(status))}

  defp status_filter(status),
    do: {:error, "invalid status: \"#{status}\" (draft | open | closed | cancelled)"}

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
