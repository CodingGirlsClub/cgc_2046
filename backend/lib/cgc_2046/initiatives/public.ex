defmodule Cgc2046.Initiatives.Public do
  @moduledoc """
  Initiative 公开投影：跨 Workspace 聚合且只返回 published public events。

  `public_url/1` 是公开页绝对链接的后端单源（`/initiatives/<slug>`）：web 侧
  sitemap 与各页 canonical 由 `web/lib/seo.ts` 生成，后端侧（MCP 工具与后续
  渠道投放）由本函数生成——base 取既有 `config :cgc_2046, :web_base_url`
  （runtime.exs：dev/test 默认 http://localhost:3000，prod 强制 WEB_BASE_URL
  https），与 `Mcp.Tools.LearnerJourney.checkout_url/1` 同款出处，不新增配置键。

  ## 生命周期可见性（#628）

  - **活动本体**：`open` / `closed` / `cancelled` 三态都可直达 + 进列表（R5 留档
    语义：slug 是投放出去就不回头的契约；`cancelled` 与 `closed` 只差文案）。
    `draft` 恒 `not_found`。
  - **场次栅格**：只有仍 `open` 的活动才挂出场次；收尾 / 中止后栅格下线（不再
    有可点进、可报名的入口），hero 与统计保留。
  """

  alias Cgc2046.Offering
  alias Cgc2046.Offering.PriceTier
  alias Cgc2046.Repo

  @doc """
  按 slug 返回活动页白名单 DTO；不存在或 draft 返回 not_found。

  事件 DTO 含**参与条件披露**（#627，全部取 Event 已物化快照列，读面不碰规则表）：
  `payment_mode` + `deposit`（缴费槽三态与押金明细）、`min_age`（年龄门槛存在性）、
  `price_range_min_cents`（收费态金额锚）、以及既有 `short_by`/`qualification_badge`
  （成班进度）。**不投**：规则原始 value map、`locked` 等治理标志、传播历史。
  """
  def get_by_slug(slug) when is_binary(slug) do
    with {:ok, initiative} <- fetch_initiative(slug),
         {:ok, events} <- fetch_events(initiative) do
      {:ok, build_payload(initiative, events)}
    end
  end

  def get_by_slug(_), do: {:error, :not_found}

  @doc "返回公开活动卡片列表；open 先于 closed 先于 cancelled（R5 + #628），供发现页入口使用。"
  def list do
    case Repo.query(
           "SELECT id, name, slug, hashtag, description, window_starts_at, window_ends_at, status FROM initiatives WHERE status IN ('open', 'closed', 'cancelled') ORDER BY CASE WHEN status = 'open' THEN 0 WHEN status = 'closed' THEN 1 ELSE 2 END, window_starts_at NULLS LAST, inserted_at DESC, id DESC LIMIT 100"
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
           "SELECT id, name, slug, hashtag, description, window_starts_at, window_ends_at, status FROM initiatives WHERE slug = $1 AND status IN ('open', 'closed', 'cancelled')",
           [slug]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, row_to_initiative(row)}
      _ -> {:error, :not_found}
    end
  end

  # 场次栅格只在活动仍 open 时显示（#628「close/cancel 后公开页不再显示挂载场」）：
  # 非 open（closed 收尾 / cancelled 中止）的活动页只剩 hero 文案与统计——留档页
  # 仍可直达（slug 是投放契约），但不再挂出任何可点进、可报名的场次。
  #
  # 判据 = 活动行自身 `status`（`fetch_initiative/1` 已读回的那一列，单源），
  # **不**复用场次侧 `status IN ('draft','open')`（#587 真源在
  # `RuleInheritance.lock_propagatable_events/1`，管的是「规则写哪些场」）。活动
  # 页显示与否是活动轴问题：用场次轴判据会同时造成「open 活动的已结束场次被抹掉」
  # 与「closed 活动的 open 场次照样挂出」两个错——两个方向都会被错误地判对。
  defp fetch_events(%{status: status}) when status != "open", do: {:ok, []}

  # 参与条件（#627）：押金三态 / 年龄门槛 / 成班进度全部取 **Event 已物化快照列**
  # （挂载时规则效果已落到 events.*），读面不碰 initiatives 规则表——零新查询面。
  defp fetch_events(initiative) do
    query = """
    SELECT e.id, e.slug, e.title, e.status, e.visibility, e.starts_at, e.ends_at,
           e.registration_deadline, e.venue,
           COUNT(en.id) FILTER (WHERE en.status = 'confirmed') AS confirmed_count,
           e.min_participants, e.qualification_status,
           e.pricing_enabled, e.deposit_enabled, e.deposit_amount_cents, e.min_age,
           e.price_tiers
    FROM events e
    LEFT JOIN enrollments en ON en.event_id = e.id
    WHERE e.initiative_id = $1
      AND e.status IN ('open', 'closed', 'cancelled')
      AND e.visibility = 'public'
    GROUP BY e.id, e.slug, e.title, e.status, e.visibility, e.starts_at, e.ends_at,
             e.registration_deadline, e.venue, e.min_participants, e.qualification_status,
             e.pricing_enabled, e.deposit_enabled, e.deposit_amount_cents, e.min_age,
             e.price_tiers
    ORDER BY e.starts_at NULLS LAST, e.inserted_at, e.id
    """

    case Repo.query(query, [uuid_param(initiative.id)]) do
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
         qualification,
         pricing_enabled,
         deposit_enabled,
         deposit_amount_cents,
         min_age,
         price_tiers
       ]) do
    # 缴费槽三态（#627）：`Offering.payment_mode/1` 只认 atom 键，裸 SQL 行不是
    # struct——判定的输入显式构 atom 键 map，**不进 DTO**（三态以 payment_mode
    # 单键表达，原始开关列不外泄；string 键会静默判成 free，见 #586 病根）。
    slot_input = %{
      pricing_enabled: pricing_enabled == true,
      deposit_enabled: deposit_enabled == true,
      deposit_amount_cents: deposit_amount_cents
    }

    slot = Offering.payment_slot(slot_input)

    %{
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
      qualification_status: qualification,
      # 年龄门槛只出**正数**（与两个金额锚同纪律）：非正来自 force write / 裸 SQL 的
      # 存量脏行（`events.min_age` 无 DB CHECK），渲染层「限 0+」比不出更糟。
      min_age: positive_int(min_age)
    }
    |> Map.merge(slot)
    |> Map.put(:price_range_min_cents, price_range_min_cents(slot.payment_mode, price_tiers))
  end

  defp positive_int(value) when is_integer(value) and value > 0, do: value
  defp positive_int(_value), do: nil

  # 收费态金额锚：**只在 pricing 态出值**——free/pricing 开关与档位是两根独立列，
  # `update_event(pricing_enabled: false)` 会把档位残留下来（无 DB CHECK 拦这一侧），
  # 那时「免费场 + 金额锚」会一并给到 agent（客户端按 mode 门控看不见，MCP 看得见）。
  # 只出**可售**档位的最小值（`PriceTier.available_tiers/1` 的 available_until
  # fail-closed 谓词与 web/MCP 同源）；原始档位数组不进公开 DTO。押金场档位恒空
  # （DB CHECK events_deposit_excludes_price_tiers）。
  defp price_range_min_cents("pricing", tiers) do
    tiers
    |> PriceTier.available_tiers()
    |> Enum.map(&Map.get(&1, "amount_cents"))
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.min(fn -> nil end)
  end

  defp price_range_min_cents(_mode, _tiers), do: nil

  # 裸 SQL 绕过 Ecto 类型加载，utc_datetime 列返回 NaiveDateTime；
  # GraphQL :datetime 标量只接受 DateTime，统一按 UTC 抬升。
  defp to_utc_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp to_utc_datetime(value), do: value

  defp uuid_param(<<_::128>> = id), do: id
  defp uuid_param(id), do: Ecto.UUID.dump!(id)

  defp uuid_text(<<_::128>> = id), do: Ecto.UUID.load!(id)
  defp uuid_text(id), do: id
end
