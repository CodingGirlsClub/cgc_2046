defmodule Cgc2046.Flashback.Public do
  @moduledoc """
  闪念间公开层投影（KTD3/U6/R32）：裸 `Repo.query` + 白名单 DTO，照
  `Cgc2046.Initiatives.Public` 范式。

  三块读面：圆梦 CTA 两态（U4）、统计层（聚合数字）、金句墙与实名档案页。
  手机/邮箱等敏感列绝不进 SELECT 列表——白名单在 SQL 层强制；金句与实名
  内容只在授权（quote_license level）成立时出现，未授权者的内容零出现。
  """

  import Ecto.Query

  alias Cgc2046.Flashback.FogSpans
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
  公开统计：场次档案（城市/年份/报名/录取数）+ 已回来人数（distinct
  person 的 link_opened touch）+ 已寄出数。空库各计数为 0——前端以
  「正在发生」进度叙事承接（U6 空态设计）。
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
    returned =
      Repo.one(
        from(t in "flashback_touches",
          join: p in "flashback_people",
          on: p.id == t.person_id,
          where: t.event == "link_opened" and is_nil(p.deleted_at),
          select: count(t.person_id, :distinct)
        )
      )

    sent =
      Repo.one(
        from(t in "flashback_todays",
          join: p in "flashback_people",
          on: p.id == t.person_id,
          where: not is_nil(t.sent_to_wall_at) and is_nil(p.deleted_at),
          select: count(t.person_id)
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

  # ── 金句墙（R31/R32：授权者的脱敏金句） ─────────────────────────────

  @doc """
  匿名金句墙（R31/R32/R36/R38）：`quote_license.level in (anonymous, credited)`、
  选定区间非空、且**未被管理端下线**（`hidden_at` 为空，R38）者——金句文本
  （区间切片）、署「姓\\*\\* · 年 · 城」。credited 者附 public_slug（可链实名页）。
  未授权者的任何内容不出现。

  ## 点赞（R36）

  - `like_count`：实时 COUNT（不落冗余计数列，去重靠 `flashback_likes` 唯一索引）；
  - `liked_by_viewer`：按客户端去重键 `voter_key`（`u:<user_id>` / `a:<device_uuid>`）
    判断本访客是否已赞；不传（nil）恒 false；
  - **排序 = 点赞数优先、更新时间次之**（涌现排序）——排序在 SQL 里做，
    `limit 60` 之后才映射 DTO，保证「最热 60 条」而不是「最新 60 条里再排」。

  `person_id` 是点赞的定位键（`flashbackLikeQuote(personId, ...)`）；投影里
  它是唯一进公开面的内部标识，除点赞外不承载任何可读信息。
  """
  def quotes(voter_key \\ nil) do
    rows =
      Repo.all(
        from(q in "flashback_quote_licenses",
          join: a in "flashback_answers",
          on:
            a.person_id == q.person_id and
              a.question_key == fragment("(?)[1]->>'question_key'", q.chosen_quote_spans),
          join: p in "flashback_people",
          on: p.id == q.person_id,
          left_join: arch in "flashback_event_archives",
          on: arch.id == p.archive_event_id,
          where:
            q.level in ["anonymous", "credited"] and
              fragment(
                "? IS NOT NULL AND array_length(?, 1) > 0",
                q.chosen_quote_spans,
                q.chosen_quote_spans
              ) and
              is_nil(q.hidden_at) and is_nil(p.deleted_at),
          # 涌现排序：点赞数优先、更新时间次之（同一子查询在 select 里复用）
          # 涌现排序：点赞数优先、更新时间次之（同一子查询在 select 里复用）
          order_by: [
            desc:
              fragment(
                "(SELECT COUNT(*) FROM flashback_likes l WHERE l.person_id = ?)",
                q.person_id
              ),
            desc: q.updated_at
          ],
          limit: 60,
          select: %{
            span: fragment("(?)[1]", q.chosen_quote_spans),
            raw_text: a.raw_text,
            full_name: p.full_name,
            surname: p.surname,
            person_id: q.person_id,
            city: fragment("COALESCE(?, ?)", p.city, arch.city),
            year: fragment("EXTRACT(YEAR FROM ?)::int", arch.occurred_on),
            level: q.level,
            public_slug: p.public_slug,
            like_count:
              fragment(
                "(SELECT COUNT(*) FROM flashback_likes l WHERE l.person_id = ?)",
                q.person_id
              ),
            liked_by_viewer:
              fragment(
                "EXISTS (SELECT 1 FROM flashback_likes l WHERE l.person_id = ? AND l.voter_key = ?)",
                q.person_id,
                ^voter_key
              )
          }
        )
      )

    {:ok,
     Enum.map(rows, fn row ->
       span = row.span || %{}
       start = span["start"] || 0
       len = span["len"] || 0

       quote_text =
         row.raw_text
         |> String.slice(start, len)
         |> FogSpans.mask(nil, @fog_placeholder)

       %{
         text: quote_text,
         attribution:
           "#{masked(row.full_name, row.surname)} · #{row.year && trunc(row.year)} · #{row.city || ""}",
         level: row.level,
         public_slug: if(row.level == "credited", do: row.public_slug),
         # 裸表查询回的是 16 字节 uuid：显式转文本（否则 Jason 序列化炸，且
         # 点赞定位要用文本 id 比对——既有「uuid binary 炸 Jason」教训同源）
         person_id: Ecto.UUID.load!(row.person_id),
         like_count: row.like_count || 0,
         liked_by_viewer: row.liked_by_viewer || false
       }
     end)}
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
