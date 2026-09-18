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
  时间胶囊总览：me（本人格）+ archives（场次时间轴与名册）+ action_cards。
  """
  @spec capsule(%{person: map()}) :: {:ok, map()} | {:error, term()}
  def capsule(%{person: person}) do
    with {:ok, archives} <- list_archives(person),
         {:ok, cards} <- list_action_cards(person.id) do
      {:ok, %{me: me_payload(person), archives: archives, action_cards: cards}}
    end
  end

  # 裸查询绕过 Ecto 类型加载：uuid 文本须 dump 成 16 字节（同 initiatives/public.ex）
  defp uuid_param(<<_::128>> = id), do: id
  defp uuid_param(id) when is_binary(id), do: Ecto.UUID.dump!(id)

  # ── 本人「今天」格（R30 撤回后回虚线 = sent_to_wall_at 为 nil） ──────

  defp me_payload(person) do
    today =
      Repo.one(
        from(t in "flashback_todays",
          where: t.person_id == ^uuid_param(person.id),
          select: %{
            now_status: t.now_status,
            want: t.want,
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
      # 候选本就排除雾面句，正常无雾；防御性仍走 mask）+ 本人当年答案雾化版
      quote: quote_text(person.id),
      answers: me_answers(person.id)
    }
  end

  # 本人金句（R14）：quote_license 选定区间应用于来源答案；off/未选 → nil
  defp quote_text(person_id) do
    Repo.one(
      from(q in "flashback_quote_licenses",
        join: a in "flashback_answers",
        on: a.person_id == q.person_id and a.question_key == q.question_key,
        where: q.person_id == ^uuid_param(person_id) and not is_nil(q.chosen_quote_span),
        limit: 1,
        select: %{raw_text: a.raw_text, span: q.chosen_quote_span}
      )
    )
    |> case do
      %{raw_text: raw_text, span: span} ->
        FogSpans.mask(String.slice(raw_text, span["start"], span["len"]), nil, @fog_placeholder)

      nil ->
        nil
    end
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

  defp list_archives(person) do
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
            attended_count: a.attended_count
          }
        )
      )

    roster_by_archive = roster_by_archive()
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
          is_mine: archive.id == uuid_param(person.archive_event_id),
          roster: roster
        }
      end)

    {:ok, enriched}
  end

  # 结构化层：attended 全量满员（姓氏隐名）；内容层由 attach_content/2 决定。
  # 已删除档案（U10/R30）整卡撤下——deleted_at 置位即从名册消失。
  defp roster_by_archive do
    rows =
      Repo.all(
        from(p in "flashback_people",
          left_join: t in "flashback_todays",
          on: t.person_id == p.id,
          where: p.participation == "attended" and is_nil(p.deleted_at),
          order_by: [asc: p.full_name],
          select: %{
            archive_event_id: p.archive_event_id,
            # uuid 文本化：裸查询默认返回 16 字节 binary，:id 标量序列化会炸
            id: fragment("?::text", p.id),
            surname: p.surname,
            full_name: p.full_name,
            city: p.city,
            occupation_then: p.occupation_then,
            sent_to_wall_at: t.sent_to_wall_at,
            now_status: t.now_status,
            want: t.want,
            say: t.say
          }
        )
      )

    Enum.group_by(rows, & &1.archive_event_id)
  end

  # 已寄出者的当年答案（雾化版）：墙上是「寄出物」，他人与自己对外同规则
  # （KTD4 一律遮蔽；本人的完整原文由 U4 enter 面承担）。
  defp wall_answers_by_person do
    rows =
      Repo.all(
        from(a in "flashback_answers",
          join: t in "flashback_todays",
          on: t.person_id == a.person_id and not is_nil(t.sent_to_wall_at),
          where: a.question_key in ["self_intro", "funny_thing", "os", "social_media"],
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
          %{
            question_key: answer.question_key,
            text: FogSpans.mask(answer.raw_text, answer.fog_spans, @fog_placeholder)
          }
        end)
      else
        []
      end

    %{
      id: row.id,
      surname: row.surname,
      surname_masked: masked_name(row.full_name, row.surname),
      city: row.city,
      occupation_then: row.occupation_then,
      sent_to_wall_at: iso8601(row.sent_to_wall_at),
      today: today,
      answers: answers
    }
  end

  # 姓氏隐名（R12）：保留姓、隐去名（surname 缺失时按 full_name 首字符兜底）
  defp masked_name(full_name, surname) when is_binary(full_name) do
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

  # ── 行动板（R13 四态） ───────────────────────────────────────────────

  defp list_action_cards(person_id) do
    rows =
      Repo.all(
        from(c in "flashback_action_cards",
          left_join: e in "flashback_endorsements",
          on: e.card_id == c.id,
          left_join: ev in "events",
          on: ev.id == c.event_id,
          group_by: [c.id, c.title, c.city, c.status, c.event_id, ev.slug, c.inserted_at],
          order_by: [asc: c.inserted_at],
          select: %{
            id: fragment("?::text", c.id),
            title: c.title,
            city: c.city,
            status: c.status,
            event_id: fragment("?::text", c.event_id),
            event_slug: ev.slug,
            endorsement_count: count(e.id),
            endorsed_by_me: fragment("BOOL_OR(? = ?)", e.person_id, ^uuid_param(person_id)),
            roles_claimed:
              fragment(
                "ARRAY_AGG(DISTINCT ?) FILTER (WHERE ? IS NOT NULL)",
                e.role_claimed,
                e.role_claimed
              )
          }
        )
      )

    cards =
      Enum.map(rows, fn row ->
        %{
          id: row.id,
          title: row.title,
          city: row.city,
          status: row.status,
          event_id: row.event_id,
          event_slug: row.event_slug,
          endorsement_count: row.endorsement_count,
          endorsed_by_me: row.endorsed_by_me || false,
          roles_claimed: row.roles_claimed || []
        }
      end)

    {:ok, cards}
  end
end
