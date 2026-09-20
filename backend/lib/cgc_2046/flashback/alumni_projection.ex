defmodule Cgc2046.Flashback.AlumniProjection do
  @moduledoc """
  校友层投影（U5/KTD3）：时间胶囊读面——场次名册（结构化层满员 + 内容层
  待点亮）、「今天」格与行动板。照 `initiatives/public.ex` 的裸查询 +
  白名单 DTO 范式；手机/邮箱不进任何 SELECT 列表。

  ## 可见性铁律（R12）

  - 名册仅含 `participation = 'attended'`（未入选者不进场次名册）；
  - 结构化卡（姓氏隐名「王\*\*」+ 城市 + 年份 + 当年职业）对**全部名册成员**
    满员默认；
  - 内容层（当年答案雾化版 + 今天摘要）**只投 `sent_to_wall_at` 非空者**——
    撤回（retract）后即刻回到结构化卡 + 虚线内容位（R30 三处呈现之一）；
  - 他人答案一律 `FogSpans.mask/3` 遮蔽后才出投影（原文零泄露）。
  """

  import Ecto.Query

  alias Cgc2046.Flashback.FogSpans
  alias Cgc2046.Flashback.Tokens
  alias Cgc2046.Repo

  @fog_placeholder "▓▓"

  @doc """
  定位本人档案：token（首程/未注册回访）或已绑定账号（R28 回访正门）。
  """
  @spec resolve_person(String.t() | nil, struct() | nil) ::
          {:ok, %{person: map(), via: :token | :account}}
          | {:error, %{code: String.t(), message: String.t(), reason: atom()}}
  def resolve_person(token, actor) do
    cond do
      is_binary(token) and token != "" ->
        case Tokens.fetch_valid(token) do
          {:ok, flashback_token} ->
            {:ok, %{person: flashback_token.person, via: :token}}

          {:error, %{code: code} = error} when is_binary(code) ->
            {:error, error}

          {:error, other} ->
            {:error,
             %{code: "flashback_token_not_found", message: inspect(other), reason: :not_found}}
        end

      not is_nil(actor) ->
        person =
          Repo.one(
            from(p in "flashback_people",
              where: p.user_id == ^uuid_param(actor.id),
              limit: 1,
              select: %{
                id: fragment("?::text", p.id),
                full_name: p.full_name,
                surname: p.surname,
                city: p.city,
                occupation_then: p.occupation_then,
                role: p.role,
                participation: p.participation,
                applied_at: p.applied_at,
                archive_event_id: p.archive_event_id,
                user_id: p.user_id
              }
            )
          )

        if is_nil(person) do
          {:error,
           %{code: "flashback_person_not_bound", message: "no archive bound", reason: :not_bound}}
        else
          {:ok, %{person: person, via: :account}}
        end

      true ->
        {:error,
         %{
           code: "flashback_auth_required",
           message: "token or sign-in required",
           reason: :auth_required
         }}
    end
  end

  @doc """
  时间胶囊总览：me（本人格）+ archives（场次时间轴与名册）+ cities。

  city（R34 城市钉）：非空时名册按城市过滤，筛空的场次整架撤下；cities 始终
  投影**全量**（钉条数据源，不随过滤收缩，否则选定城市后其余钉消失、无法切
  回「全部」）。
  """
  @spec capsule(%{person: map()}, String.t() | nil) :: {:ok, map()} | {:error, term()}
  def capsule(%{person: person}, city \\ nil) do
    future_frames = list_future_events(clean_city(city))

    with {:ok, archives} <- list_archives(person, city) do
      endorsed = Cgc2046.Flashback.Wishes.endorsed_wish_ids(person.id)

      {:ok,
       %{
         me: me_payload(person),
         archives: archives,
         public_wishes:
           Cgc2046.Flashback.Wishes.list_public(clean_city(city), person.id)
           |> Enum.map(fn wish ->
             Map.put(wish, :endorsed_by_me, MapSet.member?(endorsed, wish.id))
           end),
         my_private_wishes: Cgc2046.Flashback.Wishes.list_private(person.id),
         future_events: future_frames,
         cities: capsule_cities()
       }}
    end
  end

  # ── 未来场次帧（KTD1：dream_target 形状 + starts_at > now + initiative 分组）──

  @doc """
  未来场次按 initiative 分组（R1/R2/R4/R16）：帧按 initiative 最早未来场次
  时间升序；场次于开始时刻自然离开未来帧（无定时任务）。城市钉筛选用
  `venue->>'city'`；满员/截止由 `enrollmentBadge` 表达（U7 渲染）。
  """
  def list_future_events(city \\ nil) do
    query = """
    SELECT e.id::text, e.slug, e.title, e.starts_at, e.venue->>'city',
           e.capacity, COUNT(en.id) FILTER (WHERE en.status = 'confirmed'),
           e.registration_deadline, i.slug, i.name, min(i.window_starts_at) OVER (PARTITION BY i.id)
    FROM events e
    JOIN initiatives i ON e.initiative_id = i.id
    LEFT JOIN enrollments en ON en.event_id = e.id
    WHERE e.visibility = 'public'
      AND e.status = 'open'
      AND i.status = 'open'
      AND e.starts_at > now()
      AND ($1::text IS NULL OR e.venue->>'city' = $1)
    GROUP BY e.id, e.slug, e.title, e.starts_at, e.venue, e.capacity,
             e.registration_deadline, i.slug, i.name, i.window_starts_at
    ORDER BY min(e.starts_at) ASC, e.starts_at ASC
    """

    rows =
      case Repo.query(query, [city]) do
        {:ok, %{rows: rows}} -> rows
        _ -> []
      end

    rows
    |> Enum.map(fn [
                     id,
                     slug,
                     title,
                     starts_at,
                     event_city,
                     capacity,
                     confirmed,
                     deadline,
                     initiative_slug,
                     initiative_name,
                     initiative_starts_at
                   ] ->
      %{
        id: id,
        slug: slug,
        title: title,
        starts_at: to_datetime(starts_at),
        city: event_city,
        capacity: capacity,
        confirmed_count: confirmed || 0,
        registration_deadline: to_datetime(deadline),
        initiative_slug: initiative_slug,
        initiative_name: initiative_name,
        initiative_starts_at: to_datetime(initiative_starts_at)
      }
    end)
    |> Enum.group_by(&{&1.initiative_slug, &1.initiative_name, &1.initiative_starts_at})
    |> Enum.map(fn {{initiative_slug, initiative_name, initiative_starts_at}, events} ->
      %{
        initiative_slug: initiative_slug,
        initiative_name: initiative_name,
        initiative_starts_at: initiative_starts_at,
        events: events
      }
    end)
    |> Enum.sort_by(&hd(&1.events).starts_at, DateTime)
  end

  # GraphQL :datetime scalar 需要 DateTime 结构（字符串会在 Absinthe 序列化时炸）
  defp to_datetime(nil), do: nil

  defp to_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp to_datetime(%DateTime{} = value), do: value

  # 空串/纯空白视为未筛（query 变量传来空串不筛）
  defp clean_city(nil), do: nil

  defp clean_city(city) when is_binary(city) do
    case String.trim(city) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # 城市钉数据源（KTD6）：名册城市 ∪ 未来场次城市（events.venue->>'city'，公开 open
  # 且未开始）∪ 公开许愿城市（未删 wishes.city）。私有许愿城市不进钉条（R9 不可
  # 由钉条推断存在）；与 roster 同口径 attended + 未删除。
  defp capsule_cities do
    roster_cities =
      Repo.all(
        from(p in "flashback_people",
          where:
            p.participation == "attended" and is_nil(p.deleted_at) and
              not is_nil(p.city) and p.city != "",
          select: p.city,
          distinct: true
        )
      )

    future_event_cities =
      Repo.query!("""
      SELECT DISTINCT e.venue->>'city'
      FROM events e
      JOIN initiatives i ON e.initiative_id = i.id
      WHERE e.visibility = 'public' AND e.status = 'open' AND i.status = 'open'
        AND e.starts_at > now()
        AND e.venue->>'city' IS NOT NULL AND e.venue->>'city' != ''
      """).rows
      |> List.flatten()

    wish_cities =
      Repo.query!("""
      SELECT DISTINCT city FROM flashback_wishes
      WHERE visibility = 'public' AND deleted_at IS NULL
        AND city IS NOT NULL AND city != ''
      """).rows
      |> List.flatten()

    (roster_cities ++ future_event_cities ++ wish_cities)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # 裸查询绕过 Ecto 类型加载：uuid 文本须 dump 成 16 字节（同 initiatives/public.ex）
  defp uuid_param(<<_::128>> = id), do: id
  defp uuid_param(id) when is_binary(id), do: Ecto.UUID.dump!(id)

  # ── 本人「今天」格（R30 撤回后回虚线 = sent_to_wall_at 为 nil） ──────

  defp me_payload(person) do
    quote = quote_payload(person.id)

    today =
      Repo.one(
        from(t in "flashback_todays",
          where: t.person_id == ^uuid_param(person.id),
          select: %{
            now_status: t.now_status,
            want: t.want,
            need: t.need,
            say: t.say,
            sent_to_wall_at: t.sent_to_wall_at
          }
        )
      )

    %{
      id: person.id,
      full_name: person.full_name,
      surname: person.surname,
      city: person.city,
      occupation_then: person.occupation_then,
      participation: person.participation,
      applied_at: iso8601(person.applied_at),
      today: today && %{today | sent_to_wall_at: iso8601(today.sent_to_wall_at)},
      # 摘要卡/全文卡数据（U5 card-export）：金句（选定区间的遮蔽版——金句
      # 候选本就排除雾面句，正常无雾；防御性仍走 mask）+ 本人当年答案雾化版。
      # quote_level（R31）：授权档位独立于金句文本——回访端恢复选中态的数据源，
      # 无授权行为 "off"（与 enter 面 progress.quote_level 同口径）。
      quote_level: quote_level(person.id),
      # 多句白名单：quote = 首句文本（摘要卡/分享卡消费面取首句），quote_spans = 全量（圈选器回显）
      quote: quote.quote,
      quote_spans: quote.quote_spans,
      # 作者侧点赞数（R36）：仅授权档 ∈ {anonymous, credited} 时返回——
      # 未授权者不在墙上，0 赞的「战绩」对本人无意义（前端只在上墙且 >0 时展示）。
      quote_stats: quote_stats(person.id),
      answers: me_answers(person.id),
      # 卡片分享（#771）：开关态 + 标识 + 本人预览（预览独立于公开门——
      # 关着也能看见自己会分享出什么）。恒提供（前端类型为可选只为兼容旧夹具）。
      card_sharing: Cgc2046.Flashback.CardSharing.state(person.id)
    }
  end

  # 本人金句的点赞数（R36）：level ∈ {anonymous, credited} 才有（否则 nil）。
  defp quote_stats(person_id) do
    case quote_level(person_id) do
      level when level in ["anonymous", "credited"] ->
        %{like_count: Cgc2046.Flashback.Likes.count_for_person(person_id)}

      _ ->
        nil
    end
  end

  # 金句授权档（R31）：每人至多一行（unique_person）；无行 = 从未设置 = "off"
  defp quote_level(person_id) do
    Repo.one(
      from(q in "flashback_quote_licenses",
        where: q.person_id == ^uuid_param(person_id),
        select: q.level
      )
    ) || "off"
  end

  # 本人金句（R14/R37，多句白名单）：quote = 首句文本（消费面取首句），
  # quote_spans = 全量区间（圈选器回显；分享 opt-in 原样回填首句 span）。
  # off/未选 → 皆 nil。每句携带自己的宿主 question_key（多句可跨题）。
  defp quote_payload(person_id) do
    case Repo.one(
           from(q in "flashback_quote_licenses",
             where: q.person_id == ^uuid_param(person_id),
             limit: 1,
             select: %{spans: q.chosen_quote_spans}
           )
         ) do
      %{spans: spans} when is_list(spans) and spans != [] ->
        texts =
          Enum.map(spans, fn span ->
            raw = answer_raw_text(person_id, span["question_key"])

            if raw do
              FogSpans.mask(String.slice(raw, span["start"], span["len"]), nil, @fog_placeholder)
            else
              nil
            end
          end)

        first_text = Enum.find(texts, fn t -> is_binary(t) and t != "" end)

        %{
          quote: first_text,
          quote_spans:
            Enum.map(spans, fn span ->
              %{question_key: span["question_key"], start: span["start"], len: span["len"]}
            end)
        }

      _ ->
        %{quote: nil, quote_spans: nil}
    end
  end

  # 宿主答案原文（多句可跨题；宿主被删的悬空句跳过文本、保留区间）。
  defp answer_raw_text(person_id, "today." <> field = _qk)
       when field in ~w(now want need say) do
    Repo.one(
      from(t in "flashback_todays",
        where: t.person_id == ^uuid_param(person_id),
        limit: 1,
        select:
          fragment(
            "case ? when 'now' then ? when 'want' then ? when 'need' then ? else ? end",
            ^field,
            t.now_status,
            t.want,
            t.need,
            t.say
          )
      )
    )
  end

  defp answer_raw_text(person_id, question_key) do
    Repo.one(
      from(a in "flashback_answers",
        where: a.person_id == ^uuid_param(person_id) and a.question_key == ^question_key,
        limit: 1,
        select: a.raw_text
      )
    )
  end

  # 本人视图（KTD4）：原文永远完整 + answer id 与既有 spans——U9 小程序
  # 「编辑雾化」的消费面；text 为雾化版（web 全文卡 R15 与本人墙卡同规则）。
  defp me_answers(person_id) do
    rows =
      Repo.all(
        from(a in "flashback_answers",
          where:
            a.person_id == ^uuid_param(person_id) and
              a.question_key in ["self_intro", "funny_thing", "os", "social_media"],
          order_by: [asc: a.inserted_at],
          select: %{
            id: fragment("?::text", a.id),
            question_key: a.question_key,
            raw_text: a.raw_text,
            fog_spans: a.fog_spans
          }
        )
      )

    Enum.map(rows, fn answer ->
      %{
        id: answer.id,
        question_key: answer.question_key,
        raw_text: answer.raw_text,
        fog_spans: answer.fog_spans || [],
        text: FogSpans.mask(answer.raw_text, answer.fog_spans, @fog_placeholder)
      }
    end)
  end

  defp iso8601(nil), do: nil

  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp iso8601(%NaiveDateTime{} = ndt),
    do: DateTime.to_iso8601(DateTime.from_naive!(ndt, "Etc/UTC"))

  # ── 场次时间轴与名册（R12 分层） ─────────────────────────────────────

  defp list_archives(person, city) do
    archives =
      Repo.all(
        from(a in "flashback_event_archives",
          order_by: [asc: a.occurred_on],
          select: %{
            id: a.id,
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

    roster_by_archive = roster_by_archive(city)
    answers_by_person = wall_answers_by_person()

    enriched =
      Enum.map(archives, fn archive ->
        roster =
          archive.id
          |> then(&Map.get(roster_by_archive, &1, []))
          |> Enum.map(&attach_content(&1, answers_by_person))

        %{
          key: archive.key,
          name: archive.name,
          city: archive.city,
          occurred_on: archive.occurred_on && Date.to_iso8601(archive.occurred_on),
          applied_count: archive.applied_count,
          attended_count: archive.attended_count,
          label: archive.label,
          is_mine: archive.id == uuid_param(person.archive_event_id),
          roster: roster
        }
      end)

    # 筛选城市时整架无人即撤（原型 D：frame 只要有任一 pile 命中就保留）
    enriched = if city, do: Enum.reject(enriched, &(&1.roster == [])), else: enriched

    {:ok, enriched}
  end

  # 结构化层：attended 全量满员（姓氏隐名）；内容层由 attach_content/2 决定。
  # 已删除档案（U10/R30）整卡撤下——deleted_at 置位即从名册消失。
  # city（R34）：按**人**的城市筛（照片堆语义，非场次城市）。
  defp roster_by_archive(city) do
    base =
      from(p in "flashback_people",
        left_join: t in "flashback_todays",
        on: t.person_id == p.id,
        where: p.participation == "attended" and is_nil(p.deleted_at),
        order_by: [asc: p.full_name],
        select: %{
          archive_event_id: p.archive_event_id,
          # uuid 文本化：裸查询默认返回 16 字节 binary，:id 标量序列化会炸
          id: fragment("?::text", p.id),
          applied_at: p.applied_at,
          surname: p.surname,
          full_name: p.full_name,
          city: p.city,
          occupation_then: p.occupation_then,
          sent_to_wall_at: t.sent_to_wall_at,
          now_status: t.now_status,
          want: t.want,
          say: t.say,
          # today 句级雾面原始区间(他人视角在输出前 mask)
          today_fog_spans: t.fog_spans
        }
      )

    rows =
      base
      |> filter_city(clean_city(city))
      |> Repo.all()
      |> Enum.map(&mask_roster_today/1)

    Enum.group_by(rows, & &1.archive_event_id)
  end

  # 他人视角(名册):today 三行按本人 fogSpans mask——雾句对外不出现原字。
  defp mask_roster_today(row) do
    fog = row[:today_fog_spans] || %{}

    %{
      row
      | now_status: FogSpans.mask(row[:now_status] || "", fog["now"], @fog_placeholder),
        want: FogSpans.mask(row[:want] || "", fog["want"], @fog_placeholder),
        say: FogSpans.mask(row[:say] || "", fog["say"], @fog_placeholder)
    }
    |> Map.delete(:today_fog_spans)
  end

  # 主表（位置 0）城市等值筛；nil 不筛
  defp filter_city(query, nil), do: query

  defp filter_city(query, city), do: where(query, [row], row.city == ^city)

  # 已寄出者的当年答案（雾化版）：墙上是「寄出物」，他人与自己对外同规则
  # （KTD4 一律遮蔽；本人的完整原文由 U4 enter 面承担）。社交媒体不进墙
  # （用户拍板：很多人没填；展示须本人授权，本期无授权开关=一律不显示——
  # 本人 enter 显影页与胶囊导出面不受影响）。
  defp wall_answers_by_person do
    rows =
      Repo.all(
        from(a in "flashback_answers",
          join: t in "flashback_todays",
          on: t.person_id == a.person_id and not is_nil(t.sent_to_wall_at),
          where: a.question_key in ["self_intro", "funny_thing", "os"],
          order_by: [asc: a.inserted_at],
          select: %{
            # 文本化与 roster entry 的 id（::text）同型——attach_content 的
            # Map.get join 才能命中（binary key 对 text id 会静默失配）
            person_id: fragment("?::text", a.person_id),
            question_key: a.question_key,
            raw_text: a.raw_text,
            fog_spans: a.fog_spans
          }
        )
      )

    Enum.group_by(rows, & &1.person_id)
  end

  defp attach_content(row, answers_by_person) do
    sent = not is_nil(row.sent_to_wall_at)

    today =
      if sent do
        %{now_status: row.now_status, want: row.want, say: row.say}
      else
        nil
      end

    answers =
      if sent do
        Enum.map(Map.get(answers_by_person, row.id, []), fn answer ->
          # 段结构（雾化视觉升级）：fog 段 text 恒空——原文字符不出 DOM，
          # 前端按 len 档位渲染纯视觉雾块
          %{
            question_key: answer.question_key,
            segments: FogSpans.segments(answer.raw_text, answer.fog_spans) |> Enum.reverse()
          }
        end)
      else
        []
      end

    %{
      id: row.id,
      surname: row.surname,
      surname_masked: masked_name(row.full_name, row.surname),
      # 寄出者卡面显示全名（用户定稿：她回来了即亮名）；未寄出者 null（R12 隐名）
      full_name: sent && row.full_name,
      applied_at: sent && iso8601(row.applied_at),
      city: row.city,
      occupation_then: row.occupation_then,
      sent_to_wall_at: iso8601(row.sent_to_wall_at),
      today: today,
      answers: answers
    }
  end

  # 姓氏隐名（R12）：保留姓、隐去名（surname 缺失时按 full_name 首字符兜底）。
  # 许愿/留言投影与 MCP 治理工具共用同一遮罩口径（U4/U9 复用单源）。
  @doc """
  person 版隐名（nil 安全）：许愿人/留言人遮罩姓的公共入口。
  未加载的 relationship（Ash.NotLoaded）也落 nil——批量投影路径漏 load 时不炸，静默隐名。
  """
  def masked_name(%{full_name: full_name, surname: surname})
      when is_binary(full_name),
      do: masked_name(full_name, surname)

  # 兜底：NotLoaded/nil/缺名 → nil（静默隐名，不炸投影）
  def masked_name(_person), do: nil

  def masked_name(full_name, surname) when is_binary(full_name) do
    cond do
      is_binary(surname) and surname != "" and String.starts_with?(full_name, surname) ->
        surname <>
          String.duplicate("*", max(String.length(full_name) - String.length(surname), 1))

      true ->
        case String.graphemes(full_name) do
          [first | rest] -> first <> String.duplicate("*", max(length(rest), 1))
          [] -> ""
        end
    end
  end

  # nil/非文本 full_name 兜底（nil 安全入口的底部子句）
  def masked_name(_full_name, _surname), do: nil
end
