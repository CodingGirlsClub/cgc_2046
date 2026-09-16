defmodule Cgc2046.Initiatives.Public do
  @moduledoc """
  Initiative 公开投影：跨 Workspace 聚合且只返回 published public events。

  `public_url/1` 是公开页绝对链接的后端单源（`/initiatives/<slug>`）：web 侧
  sitemap 与各页 canonical 由 `web/lib/seo.ts` 生成，后端侧（MCP 工具与后续
  渠道投放）由本函数生成——base 取既有 `config :cgc_2046, :web_base_url`
  （runtime.exs：dev/test 默认 http://localhost:3000，prod 强制 WEB_BASE_URL
  https），与 `Mcp.Tools.LearnerJourney.checkout_url/1` 同款出处，不新增配置键。
  """

  alias Cgc2046.Repo

  @doc "按 slug 返回活动页白名单 DTO；不存在或 draft 返回 not_found。"
  def get_by_slug(slug) when is_binary(slug) do
    with {:ok, initiative} <- fetch_initiative(slug),
         {:ok, events} <- fetch_events(initiative.id) do
      {:ok, build_payload(initiative, events)}
    end
  end

  def get_by_slug(_), do: {:error, :not_found}

  @doc "返回公开活动卡片列表；open 先于 closed（R5），供发现页入口使用。"
  def list do
    case Repo.query(
           "SELECT id, name, slug, hashtag, description, window_starts_at, window_ends_at, status FROM initiatives WHERE status IN ('open', 'closed') ORDER BY CASE WHEN status = 'open' THEN 0 ELSE 1 END, window_starts_at NULLS LAST, inserted_at DESC, id DESC LIMIT 100"
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &row_to_initiative/1)}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  @doc """
  Initiative 公开详情页绝对链接（游客可读、可直达、可被搜索引擎索引）。

  slug 为空返回 nil——调用方据此不做链接渲染。
  """
  @spec public_url(String.t() | nil) :: String.t() | nil
  def public_url(nil), do: nil

  def public_url(slug) when is_binary(slug) do
    base =
      Application.get_env(:cgc_2046, :web_base_url, "http://localhost:3000")
      |> to_string()
      |> String.trim_trailing("/")

    "#{base}/initiatives/#{URI.encode_www_form(slug)}"
  end

  defp fetch_initiative(slug) do
    case Repo.query(
           "SELECT id, name, slug, hashtag, description, window_starts_at, window_ends_at, status FROM initiatives WHERE slug = $1 AND status IN ('open', 'closed')",
           [slug]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, row_to_initiative(row)}
      _ -> {:error, :not_found}
    end
  end

  defp fetch_events(initiative_id) do
    query = """
    SELECT e.id, e.slug, e.title, e.status, e.visibility, e.starts_at, e.ends_at,
           e.registration_deadline, e.venue,
           COUNT(en.id) FILTER (WHERE en.status = 'confirmed') AS confirmed_count,
           e.min_participants, e.qualification_status
    FROM events e
    LEFT JOIN enrollments en ON en.event_id = e.id
    WHERE e.initiative_id = $1
      AND e.status IN ('open', 'closed', 'cancelled')
      AND e.visibility = 'public'
    GROUP BY e.id, e.slug, e.title, e.status, e.visibility, e.starts_at, e.ends_at,
             e.registration_deadline, e.venue, e.min_participants, e.qualification_status
    ORDER BY e.starts_at NULLS LAST, e.inserted_at, e.id
    """

    case Repo.query(query, [uuid_param(initiative_id)]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn row ->
           event = row_to_event(row)
           Map.merge(event, Cgc2046.Events.QualificationBadge.badge(event, event.confirmed_count))
         end)}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  defp build_payload(initiative, events) do
    groups =
      events
      |> Enum.group_by(&city_key/1)
      |> Enum.sort_by(fn {city, _} -> city end)
      |> Enum.map(fn {city, rows} -> %{city: city, events: rows} end)

    confirmed = Enum.count(events, &(&1.qualification_status == "confirmed"))

    %{
      id: initiative.id,
      name: initiative.name,
      slug: initiative.slug,
      url: public_url(initiative.slug),
      hashtag: initiative.hashtag,
      description: initiative.description,
      window_starts_at: initiative.window_starts_at,
      window_ends_at: initiative.window_ends_at,
      status: initiative.status,
      city_count: length(groups),
      event_count: length(events),
      confirmed_count: count_confirmed(events),
      qualified_event_count: confirmed,
      cities: groups
    }
  end

  defp count_confirmed(events) do
    Enum.reduce(events, 0, fn event, acc -> acc + event.confirmed_count end)
  end

  defp city_key(%{venue: venue}) when is_map(venue) do
    case venue["city"] || venue[:city] do
      city when is_binary(city) and city != "" -> city
      _ -> "线上 / 待定"
    end
  end

  defp city_key(_), do: "线上 / 待定"

  defp row_to_initiative([id, name, slug, hashtag, description, starts, ends, status]),
    do: %{
      id: uuid_text(id),
      name: name,
      slug: slug,
      url: public_url(slug),
      hashtag: hashtag,
      description: description,
      window_starts_at: to_utc_datetime(starts),
      window_ends_at: to_utc_datetime(ends),
      status: status
    }

  defp row_to_event([
         id,
         slug,
         title,
         status,
         visibility,
         starts,
         ends,
         deadline,
         venue,
         confirmed,
         min,
         qualification
       ]),
       do: %{
         id: uuid_text(id),
         slug: slug,
         title: title,
         status: status,
         visibility: visibility,
         starts_at: to_utc_datetime(starts),
         ends_at: to_utc_datetime(ends),
         registration_deadline: to_utc_datetime(deadline),
         venue: venue,
         confirmed_count: confirmed || 0,
         min_participants: min,
         qualification_status: qualification
       }

  # 裸 SQL 绕过 Ecto 类型加载，utc_datetime 列返回 NaiveDateTime；
  # GraphQL :datetime 标量只接受 DateTime，统一按 UTC 抬升。
  defp to_utc_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp to_utc_datetime(value), do: value

  defp uuid_param(<<_::128>> = id), do: id
  defp uuid_param(id), do: Ecto.UUID.dump!(id)

  defp uuid_text(<<_::128>> = id), do: Ecto.UUID.load!(id)
  defp uuid_text(id), do: id
end
