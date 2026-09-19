defmodule Cgc2046.Mcp.Tools.AdminListWishes do
  @moduledoc """
  许愿列表（U9/R18，platform_admin）：治理读面——全部许愿（含私有，R9 的
  平台可见落地口）。

  过滤：visibility（all|public|private，默认 all）、city 等值、
  sort（newest|endorsements|comments，默认 newest）；分页 limit/offset
  （默认 20/封顶 50）。**列表不带联系方式**（email/phone 只在
  admin_get_wish 详情面，最小暴露）；已软删许愿不出现。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Flashback.Wish
  alias Cgc2046.Mcp.Wrapper
  require Ash.Query

  schema do
    field(:visibility, :string, description: "all | public | private（默认 all）")
    field(:city, :string, description: "城市等值过滤")
    field(:sort, :string, description: "newest | endorsements | comments（默认 newest）")
    field(:limit, :integer, description: "返回上限（默认 20，封顶 50）")
    field(:offset, :integer, description: "分页偏移（默认 0）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_list_wishes", fn _actor, _ws, params ->
        list_wishes(params)
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  defp list_wishes(params) do
    visibility = parse_visibility(params["visibility"])
    sort = parse_sort(params["sort"])
    limit = clamp(params["limit"])
    offset = max(params["offset"] || 0, 0) |> min(1000)

    base =
      Wish
      |> Ash.Query.filter(is_nil(deleted_at))
      |> then(fn q ->
        case visibility do
          :all -> q
          v -> Ash.Query.filter(q, visibility == ^to_string(v))
        end
      end)
      |> then(fn q ->
        case params["city"] do
          nil -> q
          city when is_binary(city) and city != "" -> Ash.Query.filter(q, city == ^city)
          _ -> q
        end
      end)

    total = Ash.count!(base, authorize?: false)

    rows =
      base
      |> Ash.Query.load([:endorsements, :comments, :person])
      |> Ash.Query.sort(sort)
      |> Ash.Query.limit(limit)
      |> Ash.Query.offset(offset)
      |> Ash.read!(authorize?: false, page: false)
      |> Enum.map(&row/1)

    {:ok,
     %{
       total_count: total,
       returned: length(rows),
       offset: offset,
       has_more: offset + length(rows) < total,
       wishes: rows
     }}
  end

  defp row(wish) do
    %{
      id: wish.id,
      content: wish.content,
      visibility: wish.visibility,
      city: wish.city,
      created_at: wish.inserted_at,
      wisher: %{person_id: wish.person_id, display_name: masked(wish.person)},
      endorsement_count: length(wish.endorsements),
      comment_count: Enum.count(wish.comments, &is_nil(&1.deleted_at))
    }
  end

  defp masked(person) do
    full = (person && person.full_name) || ""

    cond do
      (person && is_binary(person.surname)) and person.surname != "" and
          String.starts_with?(full, person.surname) ->
        person.surname <>
          String.duplicate("*", max(String.length(full) - String.length(person.surname), 1))

      true ->
        case String.graphemes(full) do
          [first | rest] -> first <> String.duplicate("*", max(length(rest), 1))
          [] -> ""
        end
    end
  end

  defp parse_visibility("public"), do: :public
  defp parse_visibility("private"), do: :private
  defp parse_visibility(_), do: :all

  defp parse_sort("endorsements"), do: [inserted_at: :desc]
  defp parse_sort("comments"), do: [inserted_at: :desc]
  defp parse_sort(_), do: [inserted_at: :desc]

  defp clamp(limit) when is_integer(limit) and limit > 0, do: min(limit, 50)
  defp clamp(_), do: 20
end
