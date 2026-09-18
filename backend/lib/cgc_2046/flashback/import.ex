defmodule Cgc2046.Flashback.Import do
  @moduledoc """
  一次性 Excel 导入编排（U3，R22/R16a）：xlsx → 标记语法解析 → 入库，
  全程可 dry-run（报告人工签收后再 `--commit` 真跑）。

  分层：

  - `Cgc2046.Flashback.Import.Xlsx`——字节流 → `%{sheet => 行×列矩阵}`；
  - `Cgc2046.Flashback.FogMarkup`——自由文本标记 → `raw_text + fog_spans`；
  - 本模块——列映射（配置化，各城表头差异）、参与状态判定（录取名单
    sheet 归属）、两份名单真源裁决、空值兜底、dry-run 报告与入库。

  ## 参与状态（R22：参与状态靠 sheet 归属，非状态列）

  行在录取名单（默认「学生」sheet）内 → `attended`（记忆线），否则
  `not_selected`（圆梦线）。匹配 key：手机号（纯数字形态）优先，
  （姓名+城市）兜底。「工作表1」（无表头备用名单）**不参与判定**，
  只进真源裁决 diff（dry-run 人工签收项）。

  ## 结构化 PII 直接标雾（R16a）

  姓名/手机/邮箱各写一行 `FlashbackAnswer`（`question_key` 为
  `full_name` / `phone` / `email`），**整段自动雾化**（span 覆盖全值）——
  平台外 agent 无须处理结构化列；`Person` 侧保持原始值（触达通道，
  admin 域，不入任何投影，KTD3）。

  ## 幂等与安全

  - EventArchive 按 `key` identity get-or-create（重跑不建重复场次）；
  - Person 无唯一约束：重跑会重复建人——`--commit` 前先看 dry-run 的
    `existing_people_in_archive`（同档案已有 N 人时须人工裁决重跑语义）；
  - 真实 PII 路径不进仓（gitleaks fail-closed），fixture 全合成。
  """

  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.Import.Xlsx

  require Ash.Query

  @default_config %{
    archive: %{
      key: "2014-01-11-bj",
      name: "Rails Girls / Girls Coding Day 北京",
      city: "北京",
      occurred_on: ~D[2014-01-11]
    },
    # 六城合一表：按城市列过滤 pilot 城市；nil = 全量。
    city_filter: "北京",
    sheet: "Sheet1",
    # 表头 → 映射。atom = Person 字段；{:answer, key} = 自由文本 Answer；
    # {:pii_answer, key} = 结构化 PII Answer（导入时整段自动雾化）。
    # 姓名的 PII Answer 由 :full_name 派生（Person 字段与雾化行同源）。
    columns: %{
      "姓名" => :full_name,
      "性别" => :gender,
      "城市" => :city,
      "手机号" => {:pii_answer, "phone"},
      "邮箱" => {:pii_answer, "email"},
      "职业" => :occupation,
      "您的电脑操作系统" => {:answer, "os"},
      "请简单的介绍一下自己" => {:answer, "self_intro"},
      "您的社交媒体" => {:answer, "social_media"},
      "请详细介绍一两件你做过的有意思的事情" => {:answer, "funny_thing"},
      "提交时间" => :applied_at
    },
    admission_sheet: "学生",
    admission_sheet_alt: "工作表1",
    role: :learner
  }

  def default_config, do: @default_config

  @doc """
  执行导入。`opts`：

  - `dry_run: true`（默认）——只产报告不写库；
  - `dry_run: false`——真跑（EventArchive get-or-create + Person + Answer）；
  - `config: %{…}`——覆盖默认列映射（深层 merge，见 `merge_config/2`）。

  返回 `{:ok, report}` 或 `{:ok, report, counts}`（真跑时 counts 为落库计数）；
  格式/结构错误返回 `{:error, reason}`（BIFF8 附转换指引）。
  """
  @spec run(binary(), keyword()) :: {:ok, map()} | {:ok, map(), map()} | {:error, term()}
  def run(xlsx_binary, opts \\ []) do
    config = merge_config(@default_config, Keyword.get(opts, :config, %{}))
    dry_run = Keyword.get(opts, :dry_run, true)

    with {:ok, sheets} <- Xlsx.read(xlsx_binary),
         {:ok, rows} <- fetch_body_rows(sheets, config),
         {:ok, admitted_keys} <- admission_keys(sheets, config),
         alt_keys = alt_admission_keys(sheets, config),
         {:ok, people} <- build_people(rows, config) do
      report = build_report(xlsx_binary, rows, people, admitted_keys, alt_keys, config)

      if dry_run do
        {:ok, report}
      else
        counts = persist(people, admitted_keys, config)
        {:ok, report, counts}
      end
    end
  end

  defp merge_config(base, overrides) do
    Map.merge(base, overrides, fn
      _k, %{} = a, %{} = b -> merge_config(a, b)
      _k, _a, b -> b
    end)
  end

  # ── 取数：表头定位 + 数据行（表头行剔除、全空行剔除、城市过滤） ──────

  defp fetch_body_rows(sheets, config) do
    sheet_name = config[:sheet]

    case Map.fetch(sheets, sheet_name) do
      {:ok, [header | body]} ->
        header = Enum.map(header, &String.trim/1)

        rows =
          body
          |> Enum.with_index(2)
          |> Enum.reject(fn {row, _} -> row == [] or Enum.all?(row, &(&1 in [nil, ""])) end)
          |> Enum.map(fn {row, idx} -> {idx, map_columns(row, header, config)} end)
          |> then(fn mapped ->
            if config[:city_filter] do
              Enum.filter(mapped, fn {_idx, cols} ->
                # 城市列缺映射/空值的行保留（交 dry-run 计数），仅按值过滤。
                get(cols, :city) == config[:city_filter]
              end)
            else
              mapped
            end
          end)

        {:ok, rows}

      {:ok, []} ->
        {:error, {:empty_sheet, sheet_name}}

      :error ->
        {:error, {:sheet_not_found, sheet_name, Map.keys(sheets)}}
    end
  end

  defp map_columns(row, header, config) do
    header
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {title, idx}, acc ->
      case Map.fetch(config[:columns], title) do
        {:ok, mapping} -> Map.put(acc, mapping, Enum.at(row, idx) || "")
        :error -> acc
      end
    end)
  end

  # ── 录取名单 key 集（手机号优先，姓名+城市兜底） ─────────────────────

  defp admission_keys(sheets, config) do
    sheet_name = config[:admission_sheet]

    case Map.fetch(sheets, sheet_name) do
      {:ok, [header | body]} ->
        header = Enum.map(header, &String.trim/1)
        phone_i = Enum.find_index(header, &(&1 in ["手机", "手机号", "联系方式"]))
        name_i = Enum.find_index(header, &(&1 in ["姓名", "名字"]))
        city_i = Enum.find_index(header, &(&1 == "城市"))

        keys =
          MapSet.new(body, fn row ->
            admission_key(cell_at(row, phone_i), cell_at(row, name_i), cell_at(row, city_i))
          end)

        {:ok, keys}

      {:ok, []} ->
        {:error, {:empty_sheet, sheet_name}}

      :error ->
        # 名单 sheet 缺失：fail-closed（参与状态无法判定）。
        {:error, {:admission_sheet_not_found, sheet_name, Map.keys(sheets)}}
    end
  end

  # 备用名单无表头（R22「工作表1」）：全部行按数据读，列位复用主名单
  # 同构猜法；只进真源裁决 diff，不参与状态判定。
  defp alt_admission_keys(sheets, config) do
    sheet_name = config[:admission_sheet_alt]

    with {:ok, alt_rows} <- Map.fetch(sheets, sheet_name),
         false <- alt_rows == [],
         {:ok, [header | _]} <- Map.fetch(sheets, config[:admission_sheet]) do
      header = Enum.map(header, &String.trim/1)
      phone_i = Enum.find_index(header, &(&1 in ["手机", "手机号", "联系方式"]))
      name_i = Enum.find_index(header, &(&1 in ["姓名", "名字"]))
      city_i = Enum.find_index(header, &(&1 == "城市"))

      MapSet.new(alt_rows, fn row ->
        admission_key(cell_at(row, phone_i), cell_at(row, name_i), cell_at(row, city_i))
      end)
    else
      _ -> MapSet.new()
    end
  end

  defp cell_at(row, index) when is_integer(index) and index >= 0,
    do: String.trim(Enum.at(row, index) || "")

  defp cell_at(_row, _), do: ""

  # 匹配 key 两侧（报名行 vs 名单行）同一归一口径：仅 11 位大陆手机做
  # {:phone, digits} key；否则 {:name_city, name, city}。口径不一致会把
  # 同一人错判成两形态 key 互不匹配（2014 pilot 记忆线 2/102 的根因之一）。
  defp admission_key(phone, name, city) do
    case normalize_phone(phone || "") do
      {:ok, digits} -> {:phone, digits}
      _ -> {:name_city, name, city}
    end
  end

  # ── 逐行构造 person + answers（标记解析 + PII 整段雾化） ─────────────

  defp build_people(rows, config) do
    rows
    |> Enum.reduce_while({:ok, []}, fn {row_idx, cols}, {:ok, acc} ->
      case build_person(row_idx, cols, config) do
        {:ok, person} -> {:cont, {:ok, [person | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, people} -> {:ok, Enum.reverse(people)}
      err -> err
    end
  end

  defp build_person(row_idx, cols, config) do
    full_name = String.trim(get(cols, :full_name))

    if full_name == "" do
      # 姓名缺失行不可导入（无身份锚点）；dry-run 报告列为 skipped。
      {:ok, %{row: row_idx, skipped: :missing_name}}
    else
      city = String.trim(get(cols, :city))

      # Person 侧联系字段（触达通道）与 PII Answer 同源取值（KTD3：原始
      # 值只进 admin 域，不进任何投影）。
      phone = phone_value(get(cols, {:pii_answer, "phone"}))
      email = blank_to_nil(get(cols, {:pii_answer, "email"}))

      with {:ok, answers} <- build_answers(row_idx, cols) do
        {applied_at_format, applied_at} = parse_applied_at(get(cols, :applied_at))

        {:ok,
         %{
           row: row_idx,
           full_name: full_name,
           surname: String.first(full_name),
           gender: blank_to_nil(get(cols, :gender)),
           city: blank_to_nil(city),
           occupation_then: blank_to_nil(get(cols, :occupation)),
           phone: phone,
           email: email,
           applied_at: applied_at,
           applied_at_format: applied_at_format,
           applied_at_raw: blank_to_nil(get(cols, :applied_at)),
           role: config[:role],
           # 姓名 PII Answer 由 Person 字段派生（R16a：结构化 PII 直接标雾）。
           answers: [
             %{question_key: "full_name", raw_text: full_name, fog_spans: [full_span(full_name)]}
             | answers
           ]
         }}
      end
    end
  end

  defp build_answers(row_idx, cols) do
    cols
    |> Enum.filter(&match?({{_, _}, _}, &1))
    |> Enum.reduce_while({:ok, []}, fn {{kind, question_key}, raw}, {:ok, acc} ->
      value = String.trim(raw || "")

      cond do
        value == "" ->
          {:cont, {:ok, acc}}

        kind == :pii_answer ->
          # 结构化 PII（手机/邮箱）：整段自动雾化，无需离线标记。
          # 手机与 Person.phone 同源归一（11 位文本），形态一致才可对账。
          value = if(question_key == "phone", do: phone_value(value), else: value)
          {:cont, {:ok, [pii_answer(question_key, value) | acc]}}

        true ->
          case Cgc2046.Flashback.FogMarkup.parse(value) do
            {:ok, raw_text, spans} ->
              {:cont,
               {:ok, [%{question_key: question_key, raw_text: raw_text, fog_spans: spans} | acc]}}

            {:error, reason} ->
              {:halt, {:error, {:fog_markup, row_idx, question_key, reason}}}
          end
      end
    end)
    |> case do
      {:ok, answers} -> {:ok, Enum.reverse(answers)}
      err -> err
    end
  end

  defp pii_answer(question_key, value) do
    %{question_key: question_key, raw_text: value, fog_spans: [full_span(value)]}
  end

  defp full_span(value), do: %{"start" => 0, "len" => String.length(value)}

  defp get(cols, key), do: Map.get(cols, key, "")

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v) when is_binary(v), do: String.trim(v)

  # 提交时间兼容两种形态（2014 pilot LibreOffice 转换副本实测）：
  # - ISO8601 文本（原始表单导出形态，2014 场已核到秒带时区，R22）；
  # - Excel 1900 日期序号（数字 cell 文本化，如 "41651.74702546"）——
  #   序号语义含 1900 假闰日惯例偏移（1900-02-29 不存在但占序号 60），
  #   墙钟按东八区解释（原始数据全部 +08:00）后转 UTC。
  # 返回 {format, datetime | nil}，format 供 dry-run 报告分形态计数。
  defp parse_applied_at(raw) do
    raw = String.trim(raw || "")

    if raw == "" do
      {:empty, nil}
    else
      case DateTime.from_iso8601(raw) do
        {:ok, dt, _offset} -> {:iso, dt}
        _ -> parse_excel_serial(raw)
      end
    end
  end

  # 序号合理域 1970-01-01（25569）～ 2099-12-31（73051）；域外视为不可解析。
  defp parse_excel_serial(raw) do
    parsed =
      if raw =~ ~r/^\d+$/, do: Integer.parse(raw), else: Float.parse(raw)

    case parsed do
      {serial, ""} when is_number(serial) and serial >= 25569 and serial <= 73051 ->
        {:serial, excel_serial_to_utc(serial)}

      _ ->
        {:unparsed, nil}
    end
  end

  defp excel_serial_to_utc(serial) do
    days = trunc(serial)
    frac = serial - days

    # 1900 假闰日：序号 ≥ 61（1900-03-01）起的真实日期 = 1899-12-31 + (days - 1)。
    adj = if days >= 61, do: days - 1, else: days
    date = Date.add(~D[1899-12-31], adj)
    secs = min(round(frac * 86400), 86399)
    time = Time.new!(div(secs, 3600), div(rem(secs, 3600), 60), rem(secs, 60))
    {:ok, wall_clock} = NaiveDateTime.new(date, time)
    # 东八区固定 +08:00（无夏令时）：墙钟 − 8h = UTC。
    {:ok, utc} =
      NaiveDateTime.add(wall_clock, -8 * 3600, :second) |> DateTime.from_naive("Etc/UTC")

    utc
  end

  # 手机号归一：文本数字（含分隔符/全角括号备注）、浮点尾（"13800138000.0"）、
  # 科学计数法（"1.3800138E10"，LibreOffice 数值 cell 文本化形态）、+86 前缀
  # → 统一 11 位文本。非 11 位大陆手机号的非空值返回 {:warn, 原文}——
  # dry-run 报警告（contact_coverage.phone_unmappable），不再静默置空。
  defp normalize_phone(raw) do
    trimmed = String.trim(raw || "")

    cond do
      trimmed == "" ->
        :empty

      true ->
        case phone_digits(trimmed) do
          {:ok, digits} -> {:ok, digits}
          :error -> {:warn, trimmed}
        end
    end
  end

  defp phone_digits(trimmed) do
    digits = String.replace(trimmed, ~r/\D/, "")

    cond do
      digits =~ ~r/^1\d{10}$/ ->
        {:ok, digits}

      # +86 前缀：13 位数字 = 86 + 11 位本体。
      String.starts_with?(digits, "86") and byte_size(digits) == 13 ->
        body = binary_part(digits, 2, 11)
        if body =~ ~r/^1\d{10}$/, do: {:ok, body}, else: :error

      # 浮点/科学计数法：先去分隔符外字符再 parseFloat，round 回整数。
      (trimmed =~ "." or trimmed =~ "e" or trimmed =~ "E") and
          trimmed =~ ~r/^[\d.\s]+[eE]?[+-]?\d*$/ ->
        case trimmed |> String.replace(~r/[\s]/, "") |> Float.parse() do
          {f, ""} ->
            int = f |> round() |> Integer.to_string()
            if int =~ ~r/^1\d{10}$/, do: {:ok, int}, else: :error

          _ ->
            :error
        end

      true ->
        :error
    end
  end

  # Person.phone / phone PII Answer 取值：归一成功存 11 位文本；不可归一的
  # 非空值保留原文（触达数据不丢，落 dry-run 警告）；空存 nil。
  defp phone_value(raw) do
    case normalize_phone(raw) do
      {:ok, digits} -> digits
      {:warn, original} -> original
      :empty -> nil
    end
  end

  # ── dry-run 报告 ─────────────────────────────────────────────────────

  defp build_report(xlsx_binary, rows, people, admitted_keys, alt_keys, config) do
    importable = Enum.filter(people, &is_map_key(&1, :full_name))
    skipped = Enum.filter(people, &(&1[:skipped] == :missing_name))

    participation =
      Enum.map(importable, fn person ->
        {person,
         if(MapSet.member?(admitted_keys, person_key(person)), do: :attended, else: :not_selected)}
      end)

    answers_all = Enum.flat_map(importable, & &1.answers)

    %{
      # R22：dry-run 报告头记录源格式与转换来源（BIFF8 在入口已被拦）。
      source_format: source_format(xlsx_binary),
      archive: config[:archive],
      city_filter: config[:city_filter],
      sheet: config[:sheet],
      rows_total: length(rows),
      rows_skipped_missing_name: length(skipped),
      skipped_rows: Enum.map(skipped, & &1.row),
      people_to_import: length(importable),
      participation: %{
        attended: count_status(participation, :attended),
        not_selected: count_status(participation, :not_selected)
      },
      attendance_source: config[:admission_sheet],
      # 真源裁决（R22）：主名单 vs 备用名单的 key 级 diff，人工签收。
      roster_reconciliation: %{
        alt_sheet: config[:admission_sheet_alt],
        only_in_primary: admitted_keys |> MapSet.difference(alt_keys) |> MapSet.size(),
        only_in_alt: alt_keys |> MapSet.difference(admitted_keys) |> MapSet.size()
      },
      # R22：约 50 行空手机号——邮箱兜底的触达覆盖面。
      contact_coverage: %{
        with_phone: Enum.count(importable, & &1.phone),
        with_email: Enum.count(importable, & &1.email),
        empty_phone_with_email: Enum.count(importable, &(!&1.phone and &1.email)),
        # 非空但不可归一为 11 位手机号的行（行号 + 原文）：警告而非静默。
        phone_unmappable:
          importable
          |> Enum.filter(fn p ->
            case normalize_phone(p.phone || "") do
              {:warn, _} -> true
              _ -> false
            end
          end)
          |> Enum.map(&{&1.row, &1.phone})
      },
      applied_at: %{
        parsed: Enum.count(importable, & &1.applied_at),
        # 两种形态各自计数（R22：报告头记录，供人工签收转换质量）。
        parsed_iso: Enum.count(importable, &(&1.applied_at_format == :iso)),
        parsed_serial: Enum.count(importable, &(&1.applied_at_format == :serial)),
        failed:
          importable
          |> Enum.filter(&(!&1.applied_at))
          |> Enum.map(&{&1.row, &1.applied_at_raw})
      },
      fog: %{
        # KTD4/U3 验收：入库 raw_text 残留标记数必须为 0；
        # spans 经 FogSpans.validate 复核（结构/重叠/越界单源）。
        residual_markers: count_residual_markers(answers_all),
        invalid_spans: count_invalid_spans(answers_all),
        spans_total: Enum.sum(Enum.map(answers_all, &length(&1.fog_spans))),
        rows_fogged: Enum.count(answers_all, &(&1.fog_spans != [])),
        pii_answers_auto_fogged:
          Enum.count(answers_all, fn a ->
            a.question_key in ["full_name", "phone", "email"] and a.fog_spans != []
          end)
      },
      existing_people_in_archive: count_existing(config[:archive][:key])
    }
  end

  defp count_status(participation, status) do
    Enum.count(participation, fn {_p, s} -> s == status end)
  end

  defp person_key(person) do
    case normalize_phone(person.phone || "") do
      {:ok, digits} -> {:phone, digits}
      _ -> {:name_city, person.full_name, person.city || ""}
    end
  end

  defp count_residual_markers(answers) do
    Enum.count(answers, fn a -> String.contains?(a.raw_text, ["⟦", "⟧"]) end)
  end

  defp count_invalid_spans(answers) do
    Enum.count(answers, fn a ->
      case Cgc2046.Flashback.FogSpans.validate(a.fog_spans, a.raw_text) do
        {:ok, _} -> false
        {:error, _} -> true
      end
    end)
  end

  defp source_format(<<"PK", _::binary>>), do: "xlsx (ZIP)"
  defp source_format(<<0xD0, 0xCF, 0x11, 0xE0, _::binary>>), do: "xls (BIFF8/OLE2)"
  defp source_format(_), do: "unknown"

  defp count_existing(archive_key) do
    case get_archive_by_key(archive_key) do
      nil ->
        0

      archive ->
        Flashback.Person
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(archive_event_id == ^archive.id)
        |> Ash.count!(authorize?: false)
    end
  end

  defp get_archive_by_key(key) do
    Flashback.EventArchive
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(key == ^key)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, archive} -> archive
      _ -> nil
    end
  end

  # ── 入库（--commit） ─────────────────────────────────────────────────

  defp persist(people, admitted_keys, config) do
    archive = ensure_archive(config[:archive])

    importable = Enum.filter(people, &is_map_key(&1, :full_name))

    Enum.reduce(importable, %{people: 0, answers: 0}, fn person, counts ->
      participation =
        if MapSet.member?(admitted_keys, person_key(person)), do: :attended, else: :not_selected

      {:ok, row} = insert_person(archive, person, participation)

      Enum.each(person.answers, fn answer ->
        Flashback.Answer
        |> Ash.Changeset.for_create(:create, %{
          person_id: row.id,
          question_key: answer.question_key,
          raw_text: answer.raw_text,
          fog_spans: answer.fog_spans
        })
        |> Ash.create!(authorize?: false)
      end)

      %{counts | people: counts.people + 1, answers: counts.answers + length(person.answers)}
    end)
  end

  defp ensure_archive(attrs) do
    case get_archive_by_key(attrs[:key]) do
      nil ->
        Flashback.EventArchive
        |> Ash.Changeset.for_create(:create, %{
          key: attrs[:key],
          name: attrs[:name],
          city: attrs[:city],
          occurred_on: attrs[:occurred_on]
        })
        |> Ash.create!(authorize?: false)

      archive ->
        archive
    end
  end

  defp insert_person(archive, person, participation) do
    Flashback.Person
    |> Ash.Changeset.for_create(:create, %{
      archive_event_id: archive.id,
      full_name: person.full_name,
      surname: person.surname,
      gender: person.gender,
      city: person.city,
      occupation_then: person.occupation_then,
      phone: person.phone,
      email: person.email,
      applied_at: person.applied_at,
      role: person.role,
      participation: participation
    })
    |> Ash.create(authorize?: false)
  end
end
