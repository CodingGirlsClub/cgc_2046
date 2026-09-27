defmodule Cgc2046.Accounts.AcquisitionStats do
  @moduledoc """
  平台级获客归因聚合（Plan 012，只读）。

  ## 度量契约（钉死）

  获客平台 = 该用户**最早一条** `user_identities.provider`
  （`DISTINCT ON (user_id) ORDER BY user_id, inserted_at, id`）；无任何身份
  （如 web 手机号直接注册）计为 `"none"`。多端登录用户只算首个平台——这是
  「谁先带来这个人」的代理口径，**不等于**「她点了哪篇小红书笔记」（没有
  笔记级 / 落点参数级字段，见 Plan 012 Owner 决策）。

  ## 导出纪律

  只返回计数（`new_users` / `enrollments` / `volunteer_applications` 各按
  平台、状态分组的整数计数），结构性无 PII——不含 user_id / 手机 / 邮箱 / 姓名。
  """

  alias Cgc2046.Repo

  @providers ~w(xhs wechat tt wechat_web none)

  @acq_cte """
  WITH acq AS (
    SELECT DISTINCT ON (ui.user_id) ui.user_id, ui.provider
    FROM user_identities ui
    ORDER BY ui.user_id, ui.inserted_at, ui.id
  )
  """

  @doc """
  聚合查询。`opts`：
  - `:since`——`DateTime`，默认 30 天前；
  - `:initiative_slug`——可选，过滤报名到该 Initiative 下的场次；
    slug 查不到 → `{:error, :initiative_not_found}`。
  """
  @spec stats(keyword()) :: {:ok, map()} | {:error, :initiative_not_found}
  def stats(opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -30, :day))
    initiative_slug = Keyword.get(opts, :initiative_slug)

    with {:ok, initiative_id} <- resolve_initiative(initiative_slug) do
      {:ok,
       %{
         window: %{since: DateTime.to_iso8601(since)},
         new_users: new_users(since),
         enrollments: enrollments(since, initiative_id),
         volunteer_applications: volunteer_applications(since)
       }}
    end
  end

  defp resolve_initiative(nil), do: {:ok, nil}

  defp resolve_initiative(slug) do
    case Repo.query("SELECT id FROM initiatives WHERE slug = $1", [slug]) do
      {:ok, %{rows: [[id]]}} -> {:ok, id}
      {:ok, %{rows: []}} -> {:error, :initiative_not_found}
    end
  end

  defp new_users(since) do
    {:ok, %{rows: rows}} =
      Repo.query(
        @acq_cte <>
          """
          SELECT COALESCE(acq.provider, 'none') AS platform, count(*)
          FROM users u
          LEFT JOIN acq ON acq.user_id = u.id
          WHERE u.inserted_at >= $1
          GROUP BY 1
          """,
        [since]
      )

    counts = Map.new(rows, fn [platform, count] -> {platform, count} end)

    Map.new(@providers, fn platform -> {platform, Map.get(counts, platform, 0)} end)
  end

  defp enrollments(since, initiative_id) do
    {query, params} =
      if initiative_id do
        {@acq_cte <>
           """
           SELECT COALESCE(acq.provider, 'none') AS platform, e.status::text, count(*)
           FROM enrollments e
           JOIN events ev ON ev.id = e.event_id
           LEFT JOIN acq ON acq.user_id = e.user_id
           WHERE e.inserted_at >= $1 AND ev.initiative_id = $2
           GROUP BY 1, 2
           """, [since, initiative_id]}
      else
        {@acq_cte <>
           """
           SELECT COALESCE(acq.provider, 'none') AS platform, e.status::text, count(*)
           FROM enrollments e
           LEFT JOIN acq ON acq.user_id = e.user_id
           WHERE e.inserted_at >= $1
           GROUP BY 1, 2
           """, [since]}
      end

    {:ok, %{rows: rows}} = Repo.query(query, params)

    Enum.map(rows, fn [platform, status, count] ->
      %{platform: platform, status: status, count: count}
    end)
  end

  defp volunteer_applications(since) do
    {:ok, %{rows: rows}} =
      Repo.query(
        @acq_cte <>
          """
          SELECT COALESCE(acq.provider, 'none') AS platform, va.status::text, count(*)
          FROM volunteer_applications va
          LEFT JOIN acq ON acq.user_id = va.user_id
          WHERE va.inserted_at >= $1
          GROUP BY 1, 2
          """,
        [since]
      )

    Enum.map(rows, fn [platform, status, count] ->
      %{platform: platform, status: status, count: count}
    end)
  end
end
