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
  - `config: %{…}`——覆盖列映射（深层 merge，见 `merge_config/2`）；
  - `preset: :learner | :coach`——大表模式 preset（`Import.MasterConfig`），
    整体替换默认 config 再叠加 `config:` 覆盖。

  返回 `{:ok, report}` 或 `{:ok, report, counts}`（真跑时 counts 为落库计数）；
  格式/结构错误返回 `{:error, reason}`（BIFF8 附转换指引）。
  """
  @spec run(binary(), keyword()) :: {:ok, map()} | {:ok, map(), map()} | {:error, term()}
  def run(xlsx_binary, opts \\ []) do
    base =
      case Keyword.get(opts, :preset) do
        nil -> @default_config
        preset -> Cgc2046.Flashback.Import.MasterConfig.config!(preset)
      end

    config = merge_config(base, Keyword.get(opts, :config, %{}))
    dry_run = Keyword.get(opts, :dry_run, true)

    with {:ok, sheets} <- Xlsx.read(xlsx_binary),
         {:ok, rows} <- fetch_body_rows(sheets, config),
         {:ok, people} <- build_people(rows, config),
         {:ok, groups} <- build_archive_groups(people, config),
         {:ok, admitted_keys} <- admitted_keys(sheets, people, config),
         alt_keys = alt_admission_keys(sheets, config) do
      report =
        build_report(xlsx_binary, rows, people, groups, admitted_keys, alt_keys, config)

      if dry_run do
        {:ok, report}
      else
        counts = persist_groups(groups, admitted_keys)
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

  # 列映射：config[:columns]（Person 字段 / Answer / PII Answer）之外，
  # 大表模式的归档列（group key + archive 三元组）按表头名单独取值进
  # 内部键——不参与 Person/Answer 写入。
  defp map_columns(row, header, config) do
    header
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {title, idx}, acc ->
      case Map.fetch(config[:columns], title) do
        {:ok, mapping} -> Map.put(acc, mapping, Enum.at(row, idx) || "")
        :error -> acc
      end
    end)
    |> put_named_column(row, header, config[:group_by], :__group__)
    |> put_named_column(row, header, archive_column(config, :name), :__archive_name__)
    |> put_named_column(row, header, archive_column(config, :city), :__archive_city__)
    |> put_named_column(row, header, archive_column(config, :date), :__archive_date__)
  end

  defp archive_column(config, field), do: get_in(config || %{}, [:archive_columns, field])

  defp put_named_column(cols, _row, _header, nil, _key), do: cols

  defp put_named_column(cols, row, header, title, key) do
    case Enum.find_index(header, &(&1 == title)) do
      nil -> cols
      idx -> Map.put(cols, key, Enum.at(row, idx) || "")
    end
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

    with true <- not is_nil(sheet_name) and config[:participation] != :column,
         {:ok, alt_rows} <- Map.fetch(sheets, sheet_name),
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

  # 参与状态 key 集（attended 集合）双源：
  # - 名单模式：录取名单 sheet 归属（R22 既现逻辑）；
  # - 列模式（participation: :column）：从已构造行的列读状态合成——
  #   下游 dedup/upgrade/report 以同一 admitted_keys 形态消费，零分叉。
  defp admitted_keys(sheets, people, config) do
    case config[:participation] do
      :column ->
        # 大表模式：attended 集合按 group 作用域合成——出席按场归档，A 场
        # attended 不得借联系方式命中把同人在 B 场标 attended（跨场传染）。
        keys =
          people
          |> Enum.filter(&is_map_key(&1, :full_name))
          |> Enum.filter(&(&1.participation == :attended))
          |> Enum.group_by(& &1.group, &person_key/1)
          |> Map.new(fn {group, ks} -> {group, MapSet.new(ks)} end)

        {:ok, keys}

      _ ->
        admission_keys(sheets, config)
    end
  end

  # admitted_keys 两形态统一取组：列模式 = %{group => MapSet}，名单模式 = MapSet。
  defp group_keys(keys, _group) when is_struct(keys, MapSet), do: keys
  defp group_keys(keys, group), do: Map.get(keys, group, MapSet.new())

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
           # 大表模式：列直读的参与状态（名单模式恒 nil，状态由 admitted_keys 判）。
           participation: column_participation(cols, config),
           # 大表模式：归档分组键与 archive 三元组（非大表模式恒空串/nil）。
           group: String.trim(get(cols, :__group__)),
           archive_name: blank_to_nil(get(cols, :__archive_name__)),
           archive_city: blank_to_nil(get(cols, :__archive_city__)),
           archive_date: blank_to_nil(get(cols, :__archive_date__)),
           # 姓名 PII Answer 由 Person 字段派生（R16a：结构化 PII 直接标雾）。
           answers: [
             %{question_key: "full_name", raw_text: full_name, fog_spans: [full_span(full_name)]}
             | answers
           ]
         }}
      end
    end
  end

  # 参与状态按列判定（大表模式 config participation: :column）：列值
  # attended 直读，其余（not_selected/空）一律 not_selected。
  defp column_participation(cols, config) do
    case config[:participation] do
      :column ->
        if String.trim(get(cols, :participation)) == "attended",
          do: :attended,
          else: :not_selected

      _ ->
        nil
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

  # 提交时间兼容三种形态（2014 pilot LibreOffice 转换副本 + 大表总表实测）：
  # - ISO8601 datetime 文本（原始表单导出形态，2014 场已核到秒带时区，R22）；
  # - ISO date 文本（大表总表统一形态，如 "2013-12-06"）——按当天 00:00 UTC；
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
        {:ok, dt, _offset} ->
          {:iso, dt}

        _ ->
          case Date.from_iso8601(raw) do
            {:ok, date} -> {:iso, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
            _ -> parse_excel_serial(raw)
          end
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

  # ── 归档分组（大表模式 group_by；名单模式单组直通） ──────────────────

  # 返回 [{archive_attrs, people_in_group}]——archive 三元组在 build_person
  # 已随行取回，此处按 key 分组并派生最终属性：
  # - name：override > 行内首个非空场次名 > 库内已有 archive（教练表后跑
  #   复用学员表建的档）——全部落空则 fail-closed {:archive_name_missing, key}；
  # - city：行内首个非空 > override > 库内已有（可空，city 列允许 nil）；
  # - occurred_on:override > 行内首个非空 ISO 日期 > 库内已有 > nil——
  #   非空但非 ISO 日期 fail-closed {:archive_date_invalid, key, raw}。
  defp build_archive_groups(people, config) do
    importable = Enum.filter(people, &is_map_key(&1, :full_name))

    if is_nil(config[:group_by]) do
      {:ok, [{config[:archive], importable}]}
    else
      groups = Enum.group_by(importable, & &1.group)

      if Map.has_key?(groups, "") do
        # 场次key 缺失的行不可归组（档案锚点缺失）——fail-closed 报行号。
        rows = groups |> Map.fetch!("") |> Enum.map(& &1.row)
        {:error, {:missing_group_key, rows}}
      else
        groups
        |> Enum.reduce_while({:ok, []}, fn {key, group_people}, {:ok, acc} ->
          case archive_attrs_for(key, group_people, config) do
            {:ok, attrs} -> {:cont, {:ok, [{attrs, group_people} | acc]}}
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, list} ->
            {:ok, Enum.reverse(list) |> Enum.sort_by(fn {attrs, _} -> attrs[:key] end)}

          err ->
            err
        end
      end
    end
  end

  defp archive_attrs_for(key, group_people, config) do
    override = Map.get(config[:archive_overrides] || %{}, key, %{})

    case nonempty(override[:name]) || first_non_empty(group_people, :archive_name) ||
           existing_archive_attr(key, :name) do
      nil ->
        {:error, {:archive_name_missing, key}}

      name ->
        with {:ok, occurred_on} <- derive_occurred_on(key, group_people, override) do
          {:ok,
           %{
             key: key,
             name: name,
             city:
               nonempty(override[:city]) || first_non_empty(group_people, :archive_city) ||
                 existing_archive_attr(key, :city),
             occurred_on: occurred_on
           }}
        end
    end
  end

  defp derive_occurred_on(key, group_people, override) do
    cond do
      raw = Map.get(override, :occurred_on) ->
        parse_archive_date(key, raw)

      raw = first_non_empty(group_people, :archive_date) ->
        parse_archive_date(key, raw)

      archive = get_archive_by_key(key) ->
        {:ok, archive.occurred_on}

      true ->
        {:ok, nil}
    end
  end

  defp parse_archive_date(_key, %Date{} = date), do: {:ok, date}

  defp parse_archive_date(key, raw) when is_binary(raw) do
    case Date.from_iso8601(raw) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, {:archive_date_invalid, key, raw}}
    end
  end

  defp nonempty(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp nonempty(_), do: nil

  defp first_non_empty(people, field) do
    Enum.find_value(people, &nonempty(Map.get(&1, field)))
  end

  defp existing_archive_attr(key, field) do
    case get_archive_by_key(key) do
      nil -> nil
      archive -> nonempty(Map.get(archive, field))
    end
  end

  # ── dry-run 报告 ─────────────────────────────────────────────────────

  defp build_report(xlsx_binary, rows, people, groups, admitted_keys, alt_keys, config) do
    importable = Enum.filter(people, &is_map_key(&1, :full_name))
    skipped = Enum.filter(people, &(&1[:skipped] == :missing_name))

    participation =
      Enum.map(importable, fn person ->
        {person,
         if(MapSet.member?(group_keys(admitted_keys, person.group), person_key(person)),
           do: :attended,
           else: :not_selected
         )}
      end)

    answers_all = Enum.flat_map(importable, & &1.answers)

    column_mode = config[:participation] == :column

    %{
      # R22：dry-run 报告头记录源格式与转换来源（BIFF8 在入口已被拦）。
      source_format: source_format(xlsx_binary),
      role: config[:role],
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
      attendance_source: if(column_mode, do: "column:参与状态", else: config[:admission_sheet]),
      # 真源裁决（R22）：主名单 vs 备用名单的 key 级 diff，人工签收。
      # 列模式无备用名单参与状态判定，恒零。
      roster_reconciliation: %{
        alt_sheet: config[:admission_sheet_alt],
        only_in_primary:
          if(column_mode,
            do: 0,
            else: admitted_keys |> MapSet.difference(alt_keys) |> MapSet.size()
          ),
        only_in_alt:
          if(column_mode,
            do: 0,
            else: alt_keys |> MapSet.difference(admitted_keys) |> MapSet.size()
          )
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
            a.question_key in ["full_name", "phone", "email", "wechat"] and a.fog_spans != []
          end)
      },
      # 大表模式（group_by）：逐个 archive 的派生快照；名单模式无此键。
      archives:
        if(config[:group_by],
          do:
            Enum.map(groups, fn {attrs, group_people} ->
              %{
                key: attrs[:key],
                name: attrs[:name],
                city: attrs[:city],
                occurred_on: attrs[:occurred_on],
                rows: length(group_people),
                existing_people: count_existing(attrs[:key])
              }
            end)
        ),
      # 库内已有此批次覆盖场次的人数（名单模式 = 单场次）。
      existing_people_in_archive:
        groups |> Enum.map(fn {attrs, _} -> count_existing(attrs[:key]) end) |> Enum.sum(),
      duplicates_in_excel: count_duplicates_in_excel(importable),
      duplicates_vs_existing:
        groups
        |> Enum.map(fn {attrs, group_people} ->
          count_duplicates_vs_existing(group_people, attrs[:key])
        end)
        |> Enum.sum(),
      duplicates_to_upgrade:
        groups
        |> Enum.map(fn {attrs, group_people} ->
          count_duplicates_to_upgrade(
            group_people,
            group_keys(admitted_keys, attrs[:key]),
            attrs[:key]
          )
        end)
        |> Enum.sum()
    }
  end

  # Excel 内重复：同 archive 内同 key 多行（取第一行，其余计入重复）——
  # 大表模式下真人跨场合法，去重边界钉在 {group, person_key}。
  defp count_duplicates_in_excel(people) do
    keys = Enum.map(people, &{&1.group, person_key(&1)})
    length(keys) - length(Enum.uniq(keys))
  end

  # 对已有重复：同 archive 内已有同 key person 的行数。
  defp count_duplicates_vs_existing(people, archive_key) do
    existing_keys = load_existing_keys(archive_key)
    Enum.count(people, fn p -> MapSet.member?(existing_keys, person_key(p)) end)
  end

  # 待升级：已有 not_selected、新行 attended（录取名单修正）的行数。
  defp count_duplicates_to_upgrade(people, admitted_keys, archive_key) do
    existing_by_key = load_existing_people_by_key(archive_key)

    Enum.count(people, fn p ->
      key = person_key(p)

      case Map.get(existing_by_key, key) do
        nil ->
          false

        existing ->
          existing.participation == :not_selected and MapSet.member?(admitted_keys, key)
      end
    end)
  end

  defp load_existing_keys(archive_key) do
    case get_archive_by_key(archive_key) do
      nil ->
        MapSet.new()

      archive ->
        Flashback.Person
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(archive_event_id == ^archive.id)
        |> Ash.read!(authorize?: false, page: false)
        |> MapSet.new(&person_key/1)
    end
  end

  defp load_existing_people_by_key(archive_key) do
    case get_archive_by_key(archive_key) do
      nil ->
        %{}

      archive ->
        Flashback.Person
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(archive_event_id == ^archive.id)
        |> Ash.read!(authorize?: false, page: false)
        |> Map.new(fn p -> {person_key(p), p} end)
    end
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

  # 逐归档分组落库并汇总计数（名单模式恒单组）。
  defp persist_groups(groups, admitted_keys) do
    Enum.reduce(groups, %{people: 0, answers: 0, upgraded: 0}, fn {attrs, people}, acc ->
      counts = persist_group(people, group_keys(admitted_keys, attrs[:key]), attrs)

      %{
        people: acc.people + counts.people,
        answers: acc.answers + counts.answers,
        upgraded: acc.upgraded + counts.upgraded
      }
    end)
  end

  defp persist_group(people, admitted_keys, archive_attrs) do
    archive = ensure_archive(archive_attrs)

    importable = Enum.filter(people, &is_map_key(&1, :full_name))
    {to_insert, to_upgrade, _skipped} = deduplicate(importable, admitted_keys, archive)

    counts =
      Enum.reduce(to_insert, %{people: 0, answers: 0}, fn person, counts ->
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

    # 录取名单修正场景：已有 not_selected、新行 attended → 仅升级 participation
    Enum.each(to_upgrade, fn {existing, _new_person} ->
      existing
      |> Ash.Changeset.for_update(:set_participation, %{participation: :attended})
      |> Ash.update!(authorize?: false)
    end)

    Map.put(counts, :upgraded, length(to_upgrade))
  end

  # 去重（同 archive 内）：Excel 内重复 + 对已有重复。返回 {待插入, 待升级,
  # 已跳过}——待升级 = 已有 not_selected、新行 attended（录取名单修正）；
  # 已跳过 = 其他重复（同 participation 或降级，不动）。
  defp deduplicate(importable, admitted_keys, archive) do
    existing_by_key =
      Flashback.Person
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(archive_event_id == ^archive.id)
      |> Ash.read!(authorize?: false)
      |> Map.new(fn p -> {person_key(p), p} end)

    Enum.reduce(importable, {[], [], []}, fn person, {insert, upgrade, skip} ->
      key = person_key(person)

      new_participation =
        if MapSet.member?(admitted_keys, key), do: :attended, else: :not_selected

      case Map.get(existing_by_key, key) do
        nil ->
          # Excel 内重复：本次 reduce 已见过此 key → 跳过
          if Enum.any?(insert, fn p -> person_key(p) == key end) do
            {insert, upgrade, [{person, :duplicate_in_excel} | skip]}
          else
            {[person | insert], upgrade, skip}
          end

        existing ->
          # 对已有重复：attended 覆盖 not_selected → 升级；其他 → 跳过
          if existing.participation == :not_selected and new_participation == :attended do
            {insert, [{existing, person} | upgrade], skip}
          else
            {insert, upgrade, [{person, :duplicate_vs_existing} | skip]}
          end
      end
    end)
    |> then(fn {insert, upgrade, skip} ->
      {Enum.reverse(insert), Enum.reverse(upgrade), Enum.reverse(skip)}
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
