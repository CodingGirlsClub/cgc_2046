defmodule Cgc2046.Flashback.Public do
  @moduledoc """
  闪念间公开层投影（KTD3/U6/R32）：裸 `Repo.query` + 白名单 DTO，照
  `Cgc2046.Initiatives.Public` 范式。

  三块读面：圆梦 CTA 两态（U4）、统计层（聚合数字）、金句墙与实名档案页。
  手机/邮箱等敏感列绝不进 SELECT 列表——白名单在 SQL 层强制；金句与实名
  内容只在授权（quote_license level）成立时出现，未授权者的内容零出现。
  """

  import Ecto.Query

  alias Cgc2046.Flashback.{FogSpans, Quotes}
  alias Cgc2046.Repo

  @fog_placeholder "▓▓"

  # ── 圆梦线 CTA 两态（U4/R9） ────────────────────────────────────────

  @doc """
  本城（city 为 nil 时不限城市）最近一场可报名的公开场次——挂在 open
  Initiative 下、自身 open + public。

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

  # ── 统计层（R32：只出聚合数字） ─────────────────────────────────────

  @doc """
  公开统计：场次档案（城市/年份/报名/录取数）+ 已回来人数 + 已寄出数。
  空库各计数为 0——前端以「正在发生」进度叙事承接（U6 空态设计）。

  N9 口径：「回来」= 打开过链接（link_opened touch）∪ 已绑定账号
  （person.user_id）∪ 已寄出（sent_to_wall_at）三者任一，distinct person；
  「寄出」是「回来」的子集——自动认领后直接寄出、绑定但未寄出的人
  不再漏计，寄出数也不可能大于回来数。
  """
  def stats do
    archives =
      Repo.all(
        from(a in "flashback_event_archives",
          order_by: [asc: a.occurred_on],
          select: %{
            key: a.key,
            name: a.name,
            city: a.city,
            occurred_on: a.occurred_on,
            applied_count: a.applied_count,
            attended_count: a.attended_count,
            label: a.label
          }
        )
      )

    # 已删除档案（U10/R30）不计入公开统计——「已回来的人」不含已行使删除权者。
    # N9：回来 = 打开过链接 ∪ 已绑定 ∪ 已寄出（任一即算，distinct person）；
    # left_join 多路径可能放大行数，靠 count(distinct) 归一
    returned =
      Repo.one(
        from(p in "flashback_people",
          left_join: ot in "flashback_touches",
          on: ot.person_id == p.id and ot.event == "link_opened",
          left_join: td in "flashback_todays",
          on: td.person_id == p.id and not is_nil(td.sent_to_wall_at),
          where:
            is_nil(p.deleted_at) and
              (not is_nil(ot.id) or not is_nil(p.user_id) or not is_nil(td.id)),
          select: count(p.id, :distinct)
        )
      )

    sent =
      Repo.one(
        from(t in "flashback_todays",
          join: p in "flashback_people",
          on: p.id == t.person_id,
          where: not is_nil(t.sent_to_wall_at) and is_nil(p.deleted_at),
          select: count(t.person_id, :distinct)
        )
      )

    {:ok,
     %{
       archives:
         Enum.map(archives, fn archive ->
           %{
             key: archive.key,
             name: archive.name,
             city: archive.city,
             occurred_on: archive.occurred_on && Date.to_iso8601(archive.occurred_on),
             applied_count: archive.applied_count,
             attended_count: archive.attended_count,
             label: archive.label
           }
         end),
       returned_count: returned || 0,
       sent_count: sent || 0
     }}
  end

  # ── 金句墙（R31/R32/R37：授权者的脱敏金句，按句输出） ─────────────────

  @doc "公开金句所在城市；不受热门 60 条限量影响，按拼音稳定排序。"
  def voice_cities do
    names =
      Repo.all(
        from(q in "flashback_quotes",
          join: ql in "flashback_quote_licenses",
          on: ql.id == q.quote_license_id,
          join: p in "flashback_people",
          on: p.id == ql.person_id,
          where:
            ql.level in ["anonymous", "credited"] and is_nil(ql.hidden_at) and
              is_nil(q.hidden_at) and is_nil(p.deleted_at),
          distinct: true,
          select: q.city
        )
      )
      |> MapSet.new()

    cities =
      Cgc2046.Flashback.Cities.list()
      |> Enum.filter(&MapSet.member?(names, &1.short_name))
      |> Enum.sort_by(&{&1.pinyin, &1.short_name})
      |> Enum.map(fn city ->
        %{
          name: city.short_name,
          full_name: city.full_name,
          pinyin: city.pinyin,
          lng_lat: city.lng_lat
        }
      end)

    {:ok, cities}
  end

  @doc """
  匿名金句墙（R31/R32/R36/R37/R38）：`quote_license.level in (anonymous, credited)`
  且**未被管理端下线**（license 与单句 `hidden_at` 均为空）者的每一句——金句
  文本（区间切片）、署「姓\\*\\* · 年 · 城」。credited 者附 public_slug
  （可链实名页）。未授权者、已撤回（hidden_at）句的任何内容零出现。

  ## 点赞（R36/R37）

  - `like_count`：按句实时 COUNT（不落冗余计数列，去重靠
    `flashback_likes` 的 `(quote_id, voter_key)` 唯一索引）；
  - `liked_by_viewer`：按客户端去重键 `voter_key`（`u:<user_id>` /
    `a:<device_uuid>`）判断本访客是否已赞；不传（nil）恒 false；
  - **排序 = 点赞数优先、更新时间次之**（涌现排序）——排序在 SQL 里做，
    `limit 60` 之后才映射 DTO，保证「最热 60 条」而不是「最新 60 条里再排」。

  `quote_id` 是点赞与单句分享的定位键（`flashbackLikeQuote(quoteId, ...)`、
  `/flashback/voices?item=<quote_id>`）；投影里它是唯一进公开面的内部标识，
  除定位外不承载任何可读信息。
  """
  def quotes(voter_key \\ nil, city \\ nil) do
    rows =
      Repo.all(
        from(q in "flashback_quotes",
          join: ql in "flashback_quote_licenses",
          on: ql.id == q.quote_license_id,
          join: p in "flashback_people",
          on: p.id == ql.person_id,
          where:
            ql.level in ["anonymous", "credited"] and
              is_nil(ql.hidden_at) and is_nil(q.hidden_at) and is_nil(p.deleted_at),
          # 城市必须在热门限量之前筛选，否则低热度城市会被全局 60 条截掉。
          where: ^is_nil(city) or q.city == ^(city || ""),
          # 涌现排序：点赞数优先、更新时间次之（同一子查询在 select 里复用）
          order_by: [
            desc:
              fragment(
                "(SELECT COUNT(*) FROM flashback_likes l WHERE l.quote_id = ?)",
                q.id
              ),
            desc: q.updated_at
          ],
          limit: 60,
          select: %{
            quote_id: q.id,
            question_key: q.question_key,
            span: q.span,
            city: q.city,
            year: q.year,
            person_id: ql.person_id,
            level: ql.level,
            full_name: p.full_name,
            surname: p.surname,
            public_slug: p.public_slug,
            like_count:
              fragment(
                "(SELECT COUNT(*) FROM flashback_likes l WHERE l.quote_id = ?)",
                q.id
              ),
            liked_by_viewer:
              fragment(
                "EXISTS (SELECT 1 FROM flashback_likes l WHERE l.quote_id = ? AND l.voter_key = ?)",
                q.id,
                ^voter_key
              )
          }
        )
      )

    {:ok, Enum.map(rows, &quote_payload(&1, voter_key))}
  end

  @doc """
  随机入口（R35「随便听听」）：全量未隐藏 Quote 中随机取 `limit` 句。
  与 `quotes/1` 同过滤口径（授权档 + 双 hidden_at + 未删除），仅排序换随机。
  """
  def random_quotes(limit, voter_key \\ nil) when is_integer(limit) and limit > 0 do
    rows =
      Repo.all(
        from(q in "flashback_quotes",
          join: ql in "flashback_quote_licenses",
          on: ql.id == q.quote_license_id,
          join: p in "flashback_people",
          on: p.id == ql.person_id,
          where:
            ql.level in ["anonymous", "credited"] and
              is_nil(ql.hidden_at) and is_nil(q.hidden_at) and is_nil(p.deleted_at),
          order_by: fragment("RANDOM()"),
          limit: ^limit,
          select: %{
            quote_id: q.id,
            question_key: q.question_key,
            span: q.span,
            city: q.city,
            year: q.year,
            person_id: ql.person_id,
            level: ql.level,
            full_name: p.full_name,
            surname: p.surname,
            public_slug: p.public_slug,
            like_count:
              fragment(
                "(SELECT COUNT(*) FROM flashback_likes l WHERE l.quote_id = ?)",
                q.id
              ),
            liked_by_viewer:
              fragment(
                "EXISTS (SELECT 1 FROM flashback_likes l WHERE l.quote_id = ? AND l.voter_key = ?)",
                q.id,
                ^voter_key
              )
          }
        )
      )

    {:ok, Enum.map(rows, &quote_payload(&1, voter_key))}
  end

  @doc """
  单句直达（R37/KTD4 分享链接 `?item=<quote_id>`）：按 id 取一句，过滤口径
  与 `quotes/1` 相同——已撤回/未授权/不存在统一返回 `{:ok, nil}`（不泄露
  「存在但未授权」与「不存在」的区别，前端据此渲染失效页）。
  """
  def quote(quote_id, voter_key \\ nil)

  def quote(quote_id, voter_key) when is_binary(quote_id) do
    # 裸表查询需 dump 后的 16 字节 uuid（与下方 like 子查询的 q.id 比较）；
    # 非法 id fail-closed 成 nil（不泄露存在性）。
    with {:ok, uuid} <- Ecto.UUID.cast(quote_id),
         {:ok, dumped} <- Ecto.UUID.dump(uuid) do
      row =
        Repo.one(
          from(q in "flashback_quotes",
            join: ql in "flashback_quote_licenses",
            on: ql.id == q.quote_license_id,
            join: p in "flashback_people",
            on: p.id == ql.person_id,
            where:
              q.id == ^dumped and
                ql.level in ["anonymous", "credited"] and
                is_nil(ql.hidden_at) and is_nil(q.hidden_at) and is_nil(p.deleted_at),
            select: %{
              quote_id: q.id,
              question_key: q.question_key,
              span: q.span,
              city: q.city,
              year: q.year,
              person_id: ql.person_id,
              level: ql.level,
              full_name: p.full_name,
              surname: p.surname,
              public_slug: p.public_slug,
              like_count:
                fragment(
                  "(SELECT COUNT(*) FROM flashback_likes l WHERE l.quote_id = ?)",
                  q.id
                ),
              liked_by_viewer:
                fragment(
                  "EXISTS (SELECT 1 FROM flashback_likes l WHERE l.quote_id = ? AND l.voter_key = ?)",
                  q.id,
                  ^voter_key
                )
            }
          )
        )

      {:ok, row && quote_payload(row, voter_key)}
    else
      _ -> {:ok, nil}
    end
  end

  def quote(_, _), do: {:ok, nil}

  # 行 → 公开 DTO：文本按 span 从宿主切片（双宿主：answer 行 / today.* 字段），
  # 雾面遮蔽在切片后施加（fail-closed：宿主缺失/雾校验失败 → 全遮蔽占位）。
  defp quote_payload(row, _voter_key) do
    span = row.span || %{}
    start = span["start"] || 0
    len = span["len"] || 0
    person_id = Ecto.UUID.load!(row.person_id)

    quote_text =
      case Quotes.host_text(person_id, row.question_key) do
        {:ok, raw_text} ->
          raw_text
          |> String.slice(start, len)
          |> FogSpans.mask(Quotes.host_fog_spans(person_id, row.question_key), @fog_placeholder)

        :error ->
          @fog_placeholder
      end

    %{
      quote_id: Ecto.UUID.load!(row.quote_id),
      text: quote_text,
      attribution:
        "#{masked(row.full_name, row.surname)} · #{row.year && trunc(row.year)} · #{row.city || ""}",
      level: row.level,
      public_slug: if(row.level == "credited", do: row.public_slug),
      city: row.city,
      year: row.year && trunc(row.year),
      like_count: row.like_count || 0,
      liked_by_viewer: row.liked_by_viewer || false
    }
  end

  # ── 实名档案页（R31 第二档/R32） ────────────────────────────────────

  @doc """
  实名档案页：仅 `public_slug` 已发布（`public_slug_published_at` 非空）且
  `quote_license.level = credited` 者可解析。内容 = 姓名/城市/年份 + 金句 +
  实名补充（credited_note）——当年答案全文不进公开范围（三层递进的默认）。
  未授权者 nil（前端 404 态）。
  """
  def profile(slug) when is_binary(slug) do
    row =
      Repo.one(
        from(p in "flashback_people",
          join: q in "flashback_quote_licenses",
          on: q.person_id == p.id and q.level == "credited",
          left_join: arch in "flashback_event_archives",
          on: arch.id == p.archive_event_id,
          where:
            p.public_slug == ^slug and not is_nil(p.public_slug_published_at) and
              fragment(
                "? IS NOT NULL AND array_length(?, 1) > 0",
                q.chosen_quote_spans,
                q.chosen_quote_spans
              ) and
              is_nil(q.hidden_at),
          left_join: a in "flashback_answers",
          on:
            a.person_id == p.id and
              a.question_key == fragment("(?)[1]->>'question_key'", q.chosen_quote_spans),
          select: %{
            full_name: p.full_name,
            city: fragment("COALESCE(?, ?)", p.city, arch.city),
            event_name: arch.name,
            year: fragment("EXTRACT(YEAR FROM ?)::int", arch.occurred_on),
            credited_note: q.credited_note,
            span: fragment("(?)[1]", q.chosen_quote_spans),
            raw_text: a.raw_text
          }
        )
      )

    case row do
      nil ->
        {:ok, nil}

      row ->
        span = row.span || %{}
        quote_text = String.slice(row.raw_text || "", span["start"] || 0, span["len"] || 0)

        {:ok,
         %{
           full_name: row.full_name,
           city: row.city,
           event_name: row.event_name,
           year: row.year && trunc(row.year),
           credited_note: row.credited_note,
           quote: quote_text
         }}
    end
  end

  def profile(_), do: {:ok, nil}

  # ── 内部 ─────────────────────────────────────────────────────────────

  defp masked(full_name, surname) when is_binary(full_name) do
    if is_binary(surname) and surname != "" and String.starts_with?(full_name, surname) do
      surname <> String.duplicate("*", max(String.length(full_name) - String.length(surname), 1))
    else
      case String.graphemes(full_name) do
        [first | rest] -> first <> String.duplicate("*", max(length(rest), 1))
        [] -> ""
      end
    end
  end

  # 裸 SQL 绕过 Ecto 类型加载，utc_datetime 列返回 NaiveDateTime；
  # GraphQL :datetime 标量只接受 DateTime，统一按 UTC 抬升（同 initiatives/public.ex）。
  defp to_utc_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp to_utc_datetime(value), do: value
end
