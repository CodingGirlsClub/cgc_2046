defmodule Cgc2046.Flashback.SharedCard do
  @moduledoc """
  卡片分享链接的公开投影（#771）：把一张档案卡投影成**匿名可读**的分享卡。

  ## 投影纪律（白名单 + 雾面零泄露）

  - 裸 `Repo.query` 风格的白名单 SELECT：只取 `full_name` / `surname` / `city` /
    `applied_at` 与当年答案、今天四格；`phone` / `email` / `gender` /
    `occupation_then` / `public_slug` / `quote_license` 等一律不进 SELECT 列表。
  - 姓名对外**恒为隐名**（`AlumniProjection.masked_name/2` 单源：王\*\*）；
    分享卡不是实名页，无任何亮名路径。
  - 当年答案与今天四格一律走 `FogSpans.segments/2`：雾面段 `text` 恒空串
    （原文字符不出响应体），只留 `len` 供前端渲染视觉档位；`fog_spans`
    坐标本身也不进投影。
  - 段序：`FogSpans.segments/2` 内部按前缀法构造（逆序），此处统一
    `Enum.reverse/1` 还原原文顺序——与名册投影同款。

  ## 可见性（与授权档/公开 slug **无依赖**）

  分享是独立开关（`flashback_people.card_share_enabled_at`）：

  - 不要求 `quote_license` 任何档位（off 也能分享）；
  - 不要求 `sent_to_wall_at`（未寄出也能分享——分享的是**实时保存的数据**，
    不是「墙上那张卡」的副本）；
  - 内容全部按当前库中数据实时投影，不落快照。

  ## 失效面

  `share_id` 未命中 / 分享已关闭 / 档案已删除（`deleted_at` 置位）一律返回
  `nil`（前端 404 态），不区分原因——不给出「这个 id 存在但关着」的存在性预言机。
  """

  import Ecto.Query

  alias Cgc2046.Flashback.AlumniProjection
  alias Cgc2046.Flashback.FogSpans
  alias Cgc2046.Repo

  # 当年答案白名单（与墙面口径同集）：社交媒体系不进对外投影。
  @historical_keys ["self_intro", "funny_thing", "os"]

  # 今天四格：GraphQL questionKey 命名（today.now / today.want / today.need / today.say）
  # → flashback_todays 列名。顺序即投影顺序（固定，不随数据变化）。
  @today_fields [
    {"today.now", :now_status},
    {"today.want", :want},
    {"today.need", :need},
    {"today.say", :say}
  ]

  @doc """
  公开分享卡：按分享标识解析（匿名可读，无 token / 无 slug / 无授权依赖）。

  返回 `nil` = 不可读（未命中 / 已关闭 / 已删除）；DB 故障照常抛出（真错误
  不吞成「没有这张卡」）。
  """
  @spec get(String.t() | nil) :: map() | nil
  def get(share_id) when is_binary(share_id) and share_id != "" do
    Repo.one(
      from(p in "flashback_people",
        join: a in "flashback_event_archives",
        on: a.id == p.archive_event_id,
        where:
          p.card_share_slug == ^share_id and not is_nil(p.card_share_enabled_at) and
            is_nil(p.deleted_at),
        select: %{
          id: fragment("?::text", p.id),
          full_name: p.full_name,
          surname: p.surname,
          city: p.city,
          applied_at: p.applied_at,
          occurred_on: a.occurred_on
        }
      )
    )
    |> case do
      nil -> nil
      row -> build(row)
    end
  end

  def get(_), do: nil

  @doc """
  本人预览（胶囊 `me.cardSharing.preview`）：与公开面**同一投影函数**，差别只在
  入口——本人预览不经过 enabled 门（关着也能看见自己会分享出什么），且不查
  `card_share_slug`（那是链接凭据，本人管理面只需要内容）。

  `person_id` 由服务端身份解析产出（token / 绑定账号），不接受客户端直传。
  """
  @spec owner_preview(String.t()) :: map() | nil
  def owner_preview(person_id) do
    Repo.one(
      from(p in "flashback_people",
        join: a in "flashback_event_archives",
        on: a.id == p.archive_event_id,
        where: p.id == ^uuid_param(person_id) and is_nil(p.deleted_at),
        select: %{
          id: fragment("?::text", p.id),
          full_name: p.full_name,
          surname: p.surname,
          city: p.city,
          applied_at: p.applied_at,
          occurred_on: a.occurred_on
        }
      )
    )
    |> case do
      nil -> nil
      row -> build(row)
    end
  end

  # ── 投影本体（公开面与本人预览共用的唯一构造点） ─────────────────────

  defp build(row) do
    %{
      display_name: AlumniProjection.masked_name(row.full_name, row.surname),
      city: row.city,
      applied_at: iso8601(row.applied_at),
      occurred_on: date_iso(row.occurred_on),
      answers: historical_sections(row.id),
      today: today_sections(row.id)
    }
  end

  # 当年答案（实时读取，不要求 sent_to_wall_at）：按导入顺序，空文本整节剔除。
  defp historical_sections(person_id) do
    Repo.all(
      from(a in "flashback_answers",
        where: a.person_id == ^uuid_param(person_id) and a.question_key in ^@historical_keys,
        order_by: [asc: a.inserted_at],
        select: %{
          question_key: a.question_key,
          raw_text: a.raw_text,
          fog_spans: a.fog_spans
        }
      )
    )
    |> Enum.map(&section(&1.question_key, &1.raw_text, &1.fog_spans))
    |> Enum.reject(&is_nil/1)
  end

  # 今天四格（实时读取，同样不要求 sent_to_wall_at）；缺列 / 空文本剔除。
  # fog_spans 形状：field("now"/"want"/"need"/"say") → spans（见 Today 资源）。
  defp today_sections(person_id) do
    case Repo.one(
           from(t in "flashback_todays",
             where: t.person_id == ^uuid_param(person_id),
             select: %{
               now_status: t.now_status,
               want: t.want,
               need: t.need,
               say: t.say,
               fog_spans: t.fog_spans
             }
           )
         ) do
      nil ->
        []

      today ->
        fog = today.fog_spans || %{}

        @today_fields
        |> Enum.map(fn {question_key, column} ->
          field = question_key |> String.split(".") |> List.last()
          section(question_key, Map.get(today, column), fog[field])
        end)
        |> Enum.reject(&is_nil/1)
    end
  end

  # 段结构：fog 段 text 恒空串（原文字符零出现）；全雾句算内容（不剔除）。
  # 无段 = 无内容（空串 / nil / 全空白）⇒ nil（调用方整节剔除）。
  defp section(question_key, text, fog_spans) do
    segments =
      text
      |> FogSpans.segments(fog_spans)
      |> Enum.reverse()

    case segments do
      [] ->
        nil

      segments ->
        %{question_key: question_key, segments: segments}
    end
  end

  # 裸查询绕过 Ecto 类型加载：uuid 文本须 dump 成 16 字节（同 alumni_projection）
  defp uuid_param(<<_::128>> = id), do: id
  defp uuid_param(id) when is_binary(id), do: Ecto.UUID.dump!(id)

  defp iso8601(nil), do: nil

  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp iso8601(%NaiveDateTime{} = ndt),
    do: DateTime.to_iso8601(DateTime.from_naive!(ndt, "Etc/UTC"))

  defp date_iso(nil), do: nil
  defp date_iso(%Date{} = d), do: Date.to_iso8601(d)
end
