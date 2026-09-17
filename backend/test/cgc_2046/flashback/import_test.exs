defmodule Cgc2046.Flashback.ImportTest do
  @moduledoc """
  U3 导入管线测试（R22/R16a）：全部用**合成 fixture**（真实 PII 不进仓，
  gitleaks fail-closed；`docs/运维/闪念间雾化标记语法.md` 的语法是解析器
  与离线 agent 的共同契约，本测试同时钉住两端）。

  覆盖：

  - FogMarkup 标记语法：基础区间/reason/转义/嵌套/未闭合/空区间/grapheme 偏移；
  - Xlsx 读取：合成 xlsx → 矩阵（sharedStrings/稀疏列）、BIFF8 拦截与转换
    指引、坏 zip；
  - Import dry-run：报告字段齐全（含源格式）、名单真源裁决、城市过滤、
    结构化 PII 自动雾化、残留标记 = 0；
  - Import --commit：场次/人数/参与状态/答案 fog_spans 落库正确。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.Import

  require Ash.Query

  @biff8_magic <<0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1>>

  # ── 合成 xlsx 构造（:zip + 最小 OOXML；读取器只消费这几个 entry） ─────

  defp build_xlsx(sheet_defs) do
    # sheet_defs: [{name, rows}]，rows: [[cell :: binary]]
    {shared_list, sheet_parts} = encode_sheets(sheet_defs)

    shared_xml = shared_strings_xml(shared_list)

    entries =
      [
        {"[Content_Types].xml", content_types_xml(length(sheet_defs))},
        {"_rels/.rels", root_rels_xml()},
        {"xl/workbook.xml", workbook_xml(Enum.map(sheet_defs, &elem(&1, 0)))},
        {"xl/_rels/workbook.xml.rels", workbook_rels_xml(length(sheet_defs))},
        {"xl/sharedStrings.xml", shared_xml}
      ] ++ sheet_parts

    # OTP :zip memory 模式要求 name 与 entry 文件名同类型（charlist）；
    # 内容保持 binary。
    charlist_entries =
      Enum.map(entries, fn {path, content} -> {String.to_charlist(path), content} end)

    {:ok, {_name, binary}} = :zip.create(~c"fixture.xlsx", charlist_entries, [:memory])
    binary
  end

  defp encode_sheets(sheet_defs) do
    {shared_acc, parts, _idx} =
      Enum.reduce(sheet_defs, {[], [], 0}, fn {name, rows}, {shared, parts, idx} ->
        sheet_no = idx + 1
        {rows_xml, shared_after} = encode_rows(rows, shared, sheet_no)

        part = {"xl/worksheets/sheet#{sheet_no}.xml", worksheet_xml(rows_xml)}
        {shared_after, [part | parts], sheet_no}
      end)

    {Enum.reverse(shared_acc) |> Enum.uniq() |> Enum.reverse(), Enum.reverse(parts)}
  end

  defp encode_rows(rows, shared, _sheet_no) do
    Enum.reduce(Enum.with_index(rows, 1), {"", shared}, fn {row, row_no}, {xml, shared_acc} ->
      {cells_xml, shared_final} =
        Enum.reduce(Enum.with_index(row, 0), {"", shared_acc}, fn {cell, col_no}, {cx, acc} ->
          {index, acc2} =
            case Enum.find_index(acc, &(&1 == cell)) do
              nil -> {length(acc), acc ++ [cell]}
              i -> {i, acc}
            end

          ref = col_letters(col_no) <> Integer.to_string(row_no)
          {cx <> ~s(<c r="#{ref}" t="s"><v>#{index}</v></c>), acc2}
        end)

      {xml <> ~s(<row r="#{row_no}">) <> cells_xml <> "</row>", shared_final}
    end)
  end

  defp col_letters(n) when n < 26, do: <<n + ?A>>
  defp col_letters(n) when n >= 26, do: col_letters(div(n, 26) - 1) <> <<rem(n, 26) + ?A>>

  defp worksheet_xml(rows_xml) do
    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      ~s(<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">) <>
      ~s(<sheetData>) <> rows_xml <> "</sheetData></worksheet>"
  end

  defp shared_strings_xml([]) do
    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      ~s(<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="0" uniqueCount="0"/>)
  end

  defp shared_strings_xml(list) do
    items = Enum.map(list, &~s(<si><t>#{xml_escape(&1)}</t></si>))

    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      ~s(<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="#{length(list)}" uniqueCount="#{length(list)}">) <>
      Enum.join(items) <> "</sst>"
  end

  defp workbook_xml(names) do
    sheets =
      names
      |> Enum.with_index(1)
      |> Enum.map_join(fn {name, i} ->
        ~s(<sheet name="#{xml_escape(name)}" sheetId="#{i}" r:id="rId#{i}"/>)
      end)

    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      ~s(<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main") <>
      ~s( xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">) <>
      "<sheets>" <> sheets <> "</sheets></workbook>"
  end

  defp workbook_rels_xml(count) do
    rels =
      Enum.map_join(1..count//1, fn i ->
        ~s(<Relationship Id="rId#{i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet#{i}.xml"/>)
      end)

    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      ~s(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">) <>
      rels <> "</Relationships>"
  end

  defp root_rels_xml do
    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      ~s(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">) <>
      ~s(<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>) <>
      "</Relationships>"
  end

  defp content_types_xml(sheet_count) do
    overrides =
      ~s(<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>) <>
        ~s(<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>) <>
        Enum.map_join(1..sheet_count//1, fn i ->
          ~s(<Override PartName="/xl/worksheets/sheet#{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>)
        end)

    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      ~s(<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">) <>
      ~s(<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>) <>
      ~s(<Default Extension="xml" ContentType="application/xml"/>) <> overrides <> "</Types>"
  end

  defp xml_escape(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  # ── fixture 数据（合成，结构对齐 2014-01-11 场：R22） ────────────────

  @header ["姓名", "性别", "城市", "手机", "邮箱", "职业", "操作系统", "自我介绍", "有意思的事", "提交时间"]

  defp sample_sheet do
    [
      @header,
      [
        "王小明",
        "女",
        "北京",
        "13900000001",
        "wxm@example.com",
        "学生",
        "Mac",
        "我在⟦盛大做测试⟧，想亲眼看看是不是。",
        "想学 Rails。",
        "2014-01-03T13:06:11+08:00"
      ],
      [
        "李雷",
        "男",
        "北京",
        "",
        "lilei@example.com",
        "产品",
        "Windows",
        "大家好。",
        "⟦和韩梅梅一起报名|同学姓名⟧",
        "2014-01-04T09:00:00+08:00"
      ],
      [
        "韩梅梅",
        "女",
        "北京",
        "13900000003",
        "",
        "设计师",
        "Linux",
        "⟦我叫韩梅梅，手机 139 0000 0003⟧想学前端。",
        "",
        "2014-01-05T18:30:00+08:00"
      ],
      [
        "张上海",
        "女",
        "上海",
        "13900000004",
        "zsh@example.com",
        "学生",
        "Mac",
        "上海报名者，不应进北京 pilot。",
        "",
        "2014-01-06T10:00:00+08:00"
      ]
    ]
  end

  # 录取名单：王小明（手机匹配）、李雷（无手机 → 姓名+城市兜底）。
  defp admission_sheet do
    [
      ["姓名", "城市", "手机"],
      ["王小明", "北京", "13900000001"],
      ["李雷", "北京", ""]
    ]
  end

  # 备用名单（无表头，R22「工作表1」同构）：多一人（赵差异）→ 真源裁决暴露。
  defp alt_sheet do
    [
      ["王小明", "北京", "13900000001"],
      ["李雷", "北京", ""],
      ["赵差异", "北京", "13900000009"]
    ]
  end

  defp fixture_xlsx do
    build_xlsx([{"Sheet1", sample_sheet()}, {"学生", admission_sheet()}, {"工作表1", alt_sheet()}])
  end

  # ── FogMarkup：标记语法 ──────────────────────────────────────────────

  describe "FogMarkup 标记语法（契约 = docs/运维/闪念间雾化标记语法.md）" do
    alias Cgc2046.Flashback.FogMarkup

    test "基础区间：剥离标记 + grapheme 偏移" do
      {:ok, raw, spans} = FogMarkup.parse("我在⟦盛大做测试⟧，想亲眼看看是不是。")

      assert raw == "我在盛大做测试，想亲眼看看是不是。"
      # "我在" 之后（grapheme 2 起，5 字）
      assert spans == [%{"start" => 2, "len" => 5}]
    end

    test "reason：第一个 | 分隔，reason 可再含 |" do
      {:ok, _raw, spans} = FogMarkup.parse("我在⟦盛大做测试|雇主|备注⟧。")
      assert spans == [%{"start" => 2, "len" => 5, "reason" => "雇主|备注"}]
    end

    test "转义：⟦⟦ / ⟧⟧ 输出字面（标记内外一致）" do
      {:ok, raw, spans} = FogMarkup.parse("前缀⟦⟦字面⟧⟧中段⟦雾⟧后缀⟧⟧")

      assert raw == "前缀⟦字面⟧中段雾后缀⟧"
      assert spans == [%{"start" => 8, "len" => 1}]
    end

    test "标记内转义：⟧⟧ 为字面 ⟧，不闭合区间" do
      {:ok, raw, spans} = FogMarkup.parse("⟦含⟧⟧字面⟧收尾")

      assert raw == "含⟧字面收尾"
      assert spans == [%{"start" => 0, "len" => 4}]
    end

    test "嵌套 → fail-closed 报错" do
      assert {:error, :nested_marker} = FogMarkup.parse("⟦外层⟦内层⟧⟧")
    end

    test "未闭合 → fail-closed 报错" do
      assert {:error, :unclosed_marker} = FogMarkup.parse("前缀⟦雾面没有关")
    end

    test "空区间（⟦⟧ 或 ⟦|仅原因⟧）→ 报错" do
      assert {:error, :empty_span} = FogMarkup.parse("⟦⟧")
      assert {:error, :empty_span} = FogMarkup.parse("⟦|只有原因⟧")
    end

    test "emoji 组合序列按单 grapheme 计数（与前端渲染口径一致）" do
      {:ok, raw, spans} = FogMarkup.parse("👩‍💻前⟦雾⟧")

      assert raw == "👩‍💻前雾"
      assert spans == [%{"start" => 2, "len" => 1}]
    end

    test "多区间有序产出，可直接过 FogSpans.validate 复核" do
      {:ok, _raw, spans} = FogMarkup.parse("⟦甲⟧乙⟦丙|因⟧丁")

      assert {:ok, _} = Cgc2046.Flashback.FogSpans.validate(spans, "甲乙丙丁")
    end
  end

  # ── Xlsx 读取 ────────────────────────────────────────────────────────

  describe "Xlsx.read（合成 xlsx）" do
    alias Cgc2046.Flashback.Import.Xlsx

    test "多 sheet + sharedStrings → 行×列矩阵" do
      {:ok, sheets} =
        build_xlsx([
          {"Sheet1", [["姓名", "城市"], ["王小明", "北京"]]},
          {"学生", [["姓名", "手机"], ["李雷", "13900000000"]]}
        ])
        |> Xlsx.read()

      assert sheets["Sheet1"] == [["姓名", "城市"], ["王小明", "北京"]]
      assert sheets["学生"] == [["姓名", "手机"], ["李雷", "13900000000"]]
    end

    test "BIFF8（OLE2 magic）→ 拦截 + 转换指引（R22 fail-closed）" do
      assert {:error, {:biff8, hint}} = Xlsx.read(@biff8_magic <> "garbage")
      assert hint =~ "另存为 .xlsx"
      assert hint =~ "soffice --convert-to xlsx"
    end

    test "非 zip 非 OLE2 → unsupported_format" do
      assert {:error, :unsupported_format} = Xlsx.read("just some text")
    end

    test "坏 zip → bad_zip" do
      assert {:error, {:bad_zip, _}} = Xlsx.read(<<"PK", "not-a-real-zip">>)
    end
  end

  # ── Import.run dry-run ───────────────────────────────────────────────

  describe "Import.run（dry-run 报告）" do
    test "报告字段齐全：源格式/城市过滤/参与状态/触达覆盖/雾化断言" do
      {:ok, report} = Import.run(fixture_xlsx())

      assert report.source_format == "xlsx (ZIP)"
      assert report.archive[:key] == "2014-01-11-bj"
      assert report.city_filter == "北京"
      assert report.sheet == "Sheet1"
      # 上海行被城市过滤剔除；北京 3 人全部可导入
      assert report.people_to_import == 3
      assert report.participation == %{attended: 2, not_selected: 1}
      assert report.attendance_source == "学生"
      # 李雷（空手机有邮箱）进邮箱兜底计数
      assert report.contact_coverage.empty_phone_with_email == 1
      assert report.contact_coverage.with_phone == 2
      assert report.applied_at.parsed == 3
      # U3 验收不变量：零残留、零非法区间
      assert report.fog.residual_markers == 0
      assert report.fog.invalid_spans == 0

      # 结构化 PII（姓名/手机/邮箱）自动整段雾化：3 人姓名 + 2 手机 + 2 邮箱
      assert report.fog.pii_answers_auto_fogged == 7
      assert report.existing_people_in_archive == 0
    end

    test "名单真源裁决：备用名单差异进报告（人工签收项）" do
      {:ok, report} = Import.run(fixture_xlsx())

      assert report.roster_reconciliation.alt_sheet == "工作表1"
      # 主名单 ⊆ 备用名单；备用多出「赵差异」
      assert report.roster_reconciliation.only_in_primary == 0
      assert report.roster_reconciliation.only_in_alt == 1
    end

    test "dry-run 不写库" do
      {:ok, _report} = Import.run(fixture_xlsx())

      assert count_archives("2014-01-11-bj") == 0
    end

    test "标记语法错误 → 行级定位报错（fail-closed，不静默丢字）" do
      bad =
        build_xlsx([
          {"Sheet1",
           [
             @header,
             [
               "王小明",
               "女",
               "北京",
               "13900000001",
               "wxm@example.com",
               "学生",
               "Mac",
               "未闭合⟦雾面",
               "x",
               "2014-01-03T13:06:11+08:00"
             ]
           ]},
          {"学生", [["姓名", "城市", "手机"], ["王小明", "北京", "13900000001"]]}
        ])

      assert {:error, {:fog_markup, 2, "self_intro", :unclosed_marker}} = Import.run(bad)
    end

    test "录取名单 sheet 缺失 → fail-closed" do
      missing =
        build_xlsx([
          {"Sheet1", [@header, List.first(sample_sheet() |> tl)]},
          {"其他", [["x"]]}
        ])

      assert {:error, {:admission_sheet_not_found, "学生", _sheets}} = Import.run(missing)
    end
  end

  # ── Import.run --commit ──────────────────────────────────────────────

  describe "Import.run（--commit 落库）" do
    test "场次/人数/参与状态/答案 fog_spans 正确；原文零标记残留" do
      {:ok, _report, counts} = Import.run(fixture_xlsx(), dry_run: false)

      assert counts.people == 3

      archive = get_archive!("2014-01-11-bj")
      assert archive.name =~ "北京"

      people =
        Flashback.Person
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(archive_event_id == ^archive.id)
        |> Ash.read!(authorize?: false)
        |> Enum.sort_by(& &1.full_name)

      assert Enum.map(people, & &1.full_name) == ["李雷", "王小明", "韩梅梅"]
      assert Enum.map(people, & &1.participation) == [:attended, :attended, :not_selected]

      wang = Enum.find(people, &(&1.full_name == "王小明"))
      assert wang.surname == "王"
      assert wang.phone == "13900000001"
      assert wang.applied_at == ~U[2014-01-03 05:06:11.000000Z]

      answers = answers_of(wang.id)
      self_intro = Enum.find(answers, &(&1.question_key == "self_intro"))

      # 标记剥离 + 区间落库（KTD4：原文不可变、fog_spans 承载遮蔽）
      assert self_intro.raw_text == "我在盛大做测试，想亲眼看看是不是。"
      assert self_intro.fog_spans == [%{"start" => 2, "len" => 5}]

      # 结构化 PII 整段雾化（R16a）
      pii_phone = Enum.find(answers, &(&1.question_key == "phone"))
      assert pii_phone.fog_spans == [%{"start" => 0, "len" => 11}]
      full_name_answer = Enum.find(answers, &(&1.question_key == "full_name"))
      assert full_name_answer.fog_spans == [%{"start" => 0, "len" => 3}]

      # 全部答案零标记残留（U3 验收）
      for answer <- answers, do: refute(String.contains?(answer.raw_text, ["⟦", "⟧"]))

      # reason 保留
      li = Enum.find(people, &(&1.full_name == "李雷"))
      funny = Enum.find(answers_of(li.id), &(&1.question_key == "funny_thing"))
      assert funny.raw_text == "和韩梅梅一起报名"
      assert funny.fog_spans == [%{"start" => 0, "len" => 8, "reason" => "同学姓名"}]
    end

    test "EventArchive 幂等（重跑不建重复场次；人叠加——dry-run 报告已警示）" do
      {:ok, _r, _c} = Import.run(fixture_xlsx(), dry_run: false)
      {:ok, report2, counts2} = Import.run(fixture_xlsx(), dry_run: false)

      assert count_archives("2014-01-11-bj") == 1
      assert report2.existing_people_in_archive == 3
      assert counts2.people == 3
    end
  end

  # ── 内部 ─────────────────────────────────────────────────────────────

  defp count_archives(key) do
    Flashback.EventArchive
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(key == ^key)
    |> Ash.count!(authorize?: false)
  end

  defp get_archive!(key) do
    Flashback.EventArchive
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(key == ^key)
    |> Ash.read_one!(authorize?: false)
  end

  defp answers_of(person_id) do
    Flashback.Answer
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(person_id == ^person_id)
    |> Ash.read!(authorize?: false)
  end
end
