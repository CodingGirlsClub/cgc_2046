defmodule Cgc2046.Flashback.Quotes do
  @moduledoc """
  单句金句（R37）的生命周期维护：Quote 行的**单一同步入口**。

  Quote 不是用户直写的实体——它是 `quote_license.chosen_quote_spans` 的
  物化投影。任何改变「哪些句应在墙上」的路径都必须经本模块收敛：

  - `sync_for_license/1`：授权档变更后调用（set_quote_license 两入口、
    雾改剪句 prune_license_after_fog）——按当前 spans 对齐 Quote 行：
    共有 span 原地更新（id 稳定，链接与点赞保留）、被剪 span 删行（其点赞
    随 FK 级联删除）、新 span 补行；
  - `sync_license_hidden/1`：license `hidden_at` 置位/清除后调用
    （QuoteLicenses.set_hidden）——级联隐藏/恢复其全部 Quote；
  - `host_text/2` / `host_fog_spans/2`：双宿主（answer 行 / today.* 字段）
    的文本与雾面读取（渲染与公开查询共用）。
  """

  require Ash.Query

  alias Cgc2046.Flashback.{Answer, Quote, QuoteLicense, Today}
  alias Cgc2046.Repo

  import Ecto.Query

  @today_host_fields ~w(now want need say)

  @doc """
  按 license 当前 `chosen_quote_spans` 对齐 Quote 行（幂等）。

  以（question_key, start, len）为身份键：三要素一致的旧行原地更新
  （id 不变）；spans 里不再出现的行删除；新 span 插入（城市/年份快照取自
  person 现值）。返回 `{:ok, quotes}`（对齐后的全集，未过滤 hidden）。
  """
  @spec sync_for_license(QuoteLicense.t()) :: {:ok, [Quote.t()]} | {:error, term()}
  def sync_for_license(%QuoteLicense{} = license) do
    # 同事务：删/插/更新分步 Ash 调用，中途失败整体回滚（不留中间态）。
    # Repo.transaction 成功路径返回 {:ok, result}——与 @spec 一致。
    Repo.transaction(fn ->
      case do_sync_for_license(license) do
        {:ok, quotes} -> quotes
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  defp do_sync_for_license(%QuoteLicense{} = license) do
    # spans 去重：同（question_key, start, len）重复元素只留首个（防重复行）。
    spans = Enum.uniq_by(license.chosen_quote_spans || [], &span_key/1)
    existing = quotes_of(license.id)
    license = Ash.load!(license, [person: :archive_event], authorize?: false)
    snapshot = snapshot_of(license.person)

    keep_keys = MapSet.new(Enum.map(spans, &span_key/1))

    # 1. 删除被剪掉的行（其点赞随 FK on_delete: :delete_all 级联）
    Enum.each(existing, fn quote ->
      unless MapSet.member?(keep_keys, span_key(quote)) do
        :ok = Ash.destroy(quote, authorize?: false)
      end
    end)

    # 2. 原地更新共有行 + 补新行
    results =
      Enum.map(spans, fn span ->
        key = span_key(span)

        case Enum.find(existing, fn quote -> span_key(quote) == key end) do
          nil ->
            Quote
            |> Ash.Changeset.for_create(:create, %{
              quote_license_id: license.id,
              answer_id: answer_id_for(license.person_id, key.question_key),
              question_key: key.question_key,
              span: %{"start" => key.start, "len" => key.len},
              city: snapshot.city,
              year: snapshot.year,
              hidden_at: license.hidden_at
            })
            |> Ash.create(authorize?: false)

          quote ->
            quote
            |> Ash.Changeset.for_update(:update, %{
              answer_id: answer_id_for(license.person_id, key.question_key),
              span: %{"start" => key.start, "len" => key.len},
              city: snapshot.city,
              year: snapshot.year
            })
            |> Ash.update(authorize?: false)
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        {:ok, quotes_of(license.id)}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  license `hidden_at` 变化后的级联：置位 → 其全部 Quote 同刻隐藏；清除 →
  全部恢复。幂等（重复调用同结果）。
  """
  @spec sync_license_hidden(QuoteLicense.t()) :: :ok
  def sync_license_hidden(%QuoteLicense{} = license) do
    Enum.each(quotes_of(license.id), fn quote ->
      if quote.hidden_at != license.hidden_at do
        {:ok, _} =
          quote
          |> Ash.Changeset.for_update(:update, %{hidden_at: license.hidden_at})
          |> Ash.update(authorize?: false)
      end
    end)

    :ok
  end

  @doc """
  某 license 当前的 Quote 行（inserted_at 升序 = 圈选顺序，首句在前）。
  """
  @spec quotes_of(String.t()) :: [Quote.t()]
  def quotes_of(license_id) do
    Quote
    |> Ash.Query.filter(quote_license_id == ^license_id)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read!(authorize?: false, page: false)
  end

  @doc """
  双宿主文本读取：answer 宿主返回 `{:ok, raw_text}`；today.* 宿主回落
  `flashback_todays` 对应字段；宿主不存在 → `:error`。
  """
  @spec host_text(String.t(), String.t()) :: {:ok, String.t()} | :error
  def host_text(person_id, "today." <> field) when field in @today_host_fields do
    case Today
         |> Ash.Query.filter(person_id == ^person_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> :error
      {:ok, today} -> {:ok, Map.get(today, today_field(field)) || ""}
    end
  end

  def host_text(person_id, question_key) do
    case Answer
         |> Ash.Query.filter(person_id == ^person_id and question_key == ^question_key)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> :error
      {:ok, answer} -> {:ok, answer.raw_text}
    end
  end

  @doc """
  双宿主的当前雾区间：today.* 取 fog_spans[field]，当年答案取
  answer.fog_spans；宿主不存在视为无雾（渲染面 fail-closed 在 mask 层）。
  """
  @spec host_fog_spans(String.t(), String.t()) :: [map()]
  def host_fog_spans(person_id, "today." <> field) when field in @today_host_fields do
    case Today
         |> Ash.Query.filter(person_id == ^person_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> []
      {:ok, today} -> Map.get(today.fog_spans || %{}, field) || []
    end
  end

  def host_fog_spans(person_id, question_key) do
    case Answer
         |> Ash.Query.filter(person_id == ^person_id and question_key == ^question_key)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> []
      {:ok, answer} -> answer.fog_spans || []
    end
  end

  @doc "today.* 宿主键识别（公开查询的宿主分支判断共用）。"
  @spec today_host?(String.t()) :: boolean()
  def today_host?(question_key), do: String.starts_with?(question_key, "today.")

  # ── 内部 ─────────────────────────────────────────────────────────────

  defp today_field("now"), do: :now_status
  defp today_field(field) when field in @today_host_fields, do: String.to_existing_atom(field)

  # （question_key, start, len）三要素 = 一句的身份键（编辑圈选 = 三要素变化
  # → 旧键行删、新键行插；「编辑原地生效保 id」指同一身份键下的字段修正）。
  defp span_key(%Quote{} = quote) do
    span = quote.span || %{}

    %{
      question_key: quote.question_key,
      start: int_of(span, "start"),
      len: int_of(span, "len")
    }
  end

  defp span_key(span) do
    %{
      question_key: Map.get(span, "question_key") || Map.get(span, :question_key),
      start: int_of(span, "start"),
      len: int_of(span, "len")
    }
  end

  defp int_of(span, key) do
    value = Map.get(span, key) || Map.get(span, String.to_existing_atom(key))
    if is_integer(value), do: value, else: 0
  end

  # today.* 宿主无 answer 行 → nil；answer 宿主按（person, question_key）定位。
  defp answer_id_for(person_id, question_key) do
    if today_host?(question_key) do
      nil
    else
      case Answer
           |> Ash.Query.filter(person_id == ^person_id and question_key == ^question_key)
           |> Ash.read_one(authorize?: false) do
        {:ok, nil} -> nil
        {:ok, answer} -> answer.id
      end
    end
  end

  # 城市/年份快照（person 现值；archive 缺失时回落至 person.city / nil 年）。
  defp snapshot_of(person) do
    archive = Map.get(person, :archive_event)

    %{
      city: person.city || (archive && archive.city),
      year: archive && archive.occurred_on && archive.occurred_on.year
    }
  end

  # 供公开查询一次性取快照（避免逐行 preload）：person_ids → %{id => %{city, year}}
  @doc false
  @spec snapshots_for([String.t()]) :: %{
          String.t() => %{city: String.t() | nil, year: integer() | nil}
        }
  def snapshots_for(person_ids) do
    Repo.all(
      from(p in "flashback_people",
        left_join: arch in "flashback_event_archives",
        on: arch.id == p.archive_event_id,
        where: p.id in ^person_ids,
        select: %{
          id: p.id,
          city: fragment("COALESCE(?, ?)", p.city, arch.city),
          year: fragment("EXTRACT(YEAR FROM ?)::int", arch.occurred_on)
        }
      )
    )
    |> Map.new(fn row -> {row.id, %{city: row.city, year: row.year && trunc(row.year)}} end)
  end
end
