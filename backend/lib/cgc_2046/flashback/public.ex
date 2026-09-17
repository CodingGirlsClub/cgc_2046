defmodule Cgc2046.Flashback.Public do
  @moduledoc """
  闪念间公开层投影（KTD3）：裸 `Repo.query` + 白名单 DTO，照
  `Cgc2046.Initiatives.Public` 范式。

  本模块只出**无个人内容**的聚合与指路数据（U4 圆梦 CTA 两态）；统计层、
  金句墙与实名档案页（R32）在 U6 落地于此。手机/邮箱等敏感列绝不进
  SELECT 列表——白名单在 SQL 层强制，而非投影层过滤。
  """

  alias Cgc2046.Repo

  @doc """
  圆梦线 CTA 两态判定（U4）：本城（city 为 nil 时不限城市）最近一场
  可报名的公开场次——挂在 open Initiative 下、自身 open + public。

  命中 → 前端直链 `/events/{event_slug}` 报名页；未命中 → 落
  Initiative 公开页（1024 区块 + 兜底出口）。只投指路字段，无个人数据。
  """
  @spec dream_target(String.t() | nil) ::
          %{
            event_slug: String.t(),
            event_title: String.t(),
            starts_at: DateTime.t() | nil,
            initiative_slug: String.t()
          }
          | nil
  def dream_target(city) do
    query = """
    SELECT e.slug, e.title, e.starts_at, i.slug
    FROM events e
    JOIN initiatives i ON e.initiative_id = i.id
    WHERE e.visibility = 'public'
      AND e.status = 'open'
      AND i.status = 'open'
      AND ($1::text IS NULL OR e.venue->>'city' = $1)
    ORDER BY e.starts_at ASC
    LIMIT 1
    """

    case Repo.query(query, [city]) do
      {:ok, %{rows: [row]}} ->
        [event_slug, event_title, starts_at, initiative_slug] = row

        %{
          event_slug: event_slug,
          event_title: event_title,
          starts_at: to_utc_datetime(starts_at),
          initiative_slug: initiative_slug
        }

      _ ->
        nil
    end
  end

  # 裸 SQL 绕过 Ecto 类型加载，utc_datetime 列返回 NaiveDateTime；
  # GraphQL :datetime 标量只接受 DateTime，统一按 UTC 抬升（同 initiatives/public.ex）。
  defp to_utc_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp to_utc_datetime(value), do: value
end
