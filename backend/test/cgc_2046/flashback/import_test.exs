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
  - Import --commit：场次/人数/参与状态/答案 fog_spans 落库正确；
  - 转换副本形态回归（2014 pilot 三缺陷）：稀疏 cell 列位展开、数值手机
    归一（科学计数/浮点尾/+86/分隔符）、Excel 1900 日期序号、名单匹配
    key 形态对齐。
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

  # cell 形态：binary = 文本（t="s"）；{:num, raw} = 数值 cell（无 t，
  # LibreOffice 数值化手机号/日期序号的载体）；{:skip, n} = 跳 n 列（构造
  # 稀疏行，验证列位展开）。
  defp encode_rows(rows, shared, _sheet_no) do
    Enum.reduce(Enum.with_index(rows, 1), {"", shared}, fn {row, row_no}, {xml, shared_acc} ->
      {cells_xml, shared_final, _col} =
        Enum.reduce(row, {"", shared_acc, 0}, fn cell, {cx, acc, col_no} ->
          encode_cell(cell, col_no, row_no, cx, acc)
        end)

      {xml <> ~s(<row r="#{row_no}">) <> cells_xml <> "</row>", shared_final}
    end)
  end

  defp encode_cell({:skip, n}, col_no, _row_no, cx, acc), do: {cx, acc, col_no + n}

  defp encode_cell({:num, raw}, col_no, row_no, cx, acc) do
    ref = col_letters(col_no) <> Integer.to_string(row_no)
    {cx <> ~s(<c r="#{ref}"><v>#{raw}</v></c>), acc, col_no + 1}
  end

  defp encode_cell(cell, col_no, row_no, cx, acc) when is_binary(cell) do
    {index, acc2} =
      case Enum.find_index(acc, &(&1 == cell)) do
        nil -> {length(acc), acc ++ [cell]}
        i -> {i, acc}
      end

    ref = col_letters(col_no) <> Integer.to_string(row_no)
    {cx <> ~s(<c r="#{ref}" t="s"><v>#{index}</v></c>), acc2, col_no + 1}
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

  @header [
    "姓名",
    "性别",
    "城市",
    "手机号",
    "邮箱",
    "职业",
    "您的电脑操作系统",
    "请简单的介绍一下自己",
    "您的社交媒体",
    "请详细介绍一两件你做过的有意思的事情",
    "提交时间"
  ]

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
        "",
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
        "",
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
        "http://weibo.com/hanmeimei",
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
        "",
        "2014-01-06T10:00:00+08:00"
      ]
    ]
  end

  # 录取名单：王小明（手机匹配）、李雷（无手机 → 姓名+城市兜底）。
  defp admission_sheet do
    [
      ["姓名", "城市", "手机号"],
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

  # Excel 内重复：Sheet1 多一行王小明（同手机号）。
  defp fixture_xlsx_with_duplicate_row do
    sheet =
      sample_sheet() ++
        [
          [
            "王小明",
            "女",
            "北京",
            "13900000001",
            "wxm2@example.com",
            "学生",
            "Mac",
            "重复行。",
            "",
            "",
            "2014-01-04T10:00:00+08:00"
          ]
        ]

    build_xlsx([{"Sheet1", sheet}, {"学生", admission_sheet()}, {"工作表1", alt_sheet()}])
  end

  # 修正后的录取名单：王小明改为 attended（原 fixture 里他不在名单 → not_selected）。
  defp fixture_xlsx_with_fixed_admission do
    admission = [
      ["姓名", "城市", "手机号"],
      ["王小明", "北京", "13900000001"],
      ["李雷", "北京", ""],
      ["韩梅梅", "北京", "13900000003"]
    ]

    build_xlsx([{"Sheet1", sample_sheet()}, {"学生", admission}, {"工作表1", alt_sheet()}])
  end

  # 录取名单不含王小明（让他在第一次导入时是 not_selected）。
  defp fixture_xlsx_without_wang_in_admission do
    admission = [
      ["姓名", "城市", "手机号"],
      ["李雷", "北京", ""]
    ]

    build_xlsx([{"Sheet1", sample_sheet()}, {"学生", admission}, {"工作表1", alt_sheet()}])
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

    # 真实来源：整合产线（pandas/et_xmlfile）产物全部标签带 x: 前缀，且部分
    # XML entry（如 workbook rels）带 UTF-8 BOM。未处理时：前缀 → 静默零 sheet；
    # BOM → rels 解析失败 → 目标 sheet 静默零行。两条都比报错恶劣。
    test "x: 命名空间前缀 + entry 带 UTF-8 BOM（整合产线真实形态）→ 正常解析" do
      wb =
        ~s(<?xml version="1.0" encoding="utf-8"?>) <>
          ~s(<x:workbook xmlns:x="http://schemas.openxmlformats.org/spreadsheetml/2006/main">) <>
          ~s(<x:sheets>) <>
          ~s(<x:sheet name="学员" sheetId="1" r:id="Rabc123" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/>) <>
          ~s(</x:sheets></x:workbook>)

      # BOM 与真实产物同位：rels entry 文件头
      rels =
        <<0xEF, 0xBB, 0xBF>> <>
          ~s(<?xml version="1.0" encoding="utf-8"?>) <>
          ~s(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">) <>
          ~s(<Relationship Id="Rabc123" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>) <>
          ~s(</Relationships>)

      sst =
        ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
          ~s(<x:sst xmlns:x="http://schemas.openxmlformats.org/spreadsheetml/2006/main">) <>
          ~s(<x:si><x:t>姓名</x:t></x:si><x:si><x:t>王小明</x:t></x:si>) <>
          ~s(</x:sst>)

      sheet =
        ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
          ~s(<x:worksheet xmlns:x="http://schemas.openxmlformats.org/spreadsheetml/2006/main">) <>
          ~s(<x:sheetData>) <>
          ~s(<x:row r="1"><x:c r="A1" t="s"><x:v>0</x:v></x:c></x:row>) <>
          ~s(<x:row r="2"><x:c r="A2" t="s"><x:v>1</x:v></x:c></x:row>) <>
          ~s(</x:sheetData></x:worksheet>)

      entries =
        [
          {"xl/workbook.xml", wb},
          {"xl/_rels/workbook.xml.rels", rels},
          {"xl/sharedStrings.xml", sst},
          {"xl/worksheets/sheet1.xml", sheet}
        ]
        |> Enum.map(fn {path, content} -> {String.to_charlist(path), content} end)

      {:ok, {_name, binary}} = :zip.create(~c"prefixed.xlsx", entries, [:memory])

      assert {:ok, %{"学员" => [["姓名"], ["王小明"]]}} = Xlsx.read(binary)
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
      assert report.applied_at.parsed_iso == 3
      assert report.applied_at.parsed_serial == 0
      assert report.contact_coverage.phone_unmappable == []
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

  # ── LibreOffice 转换副本形态（2014 pilot 三缺陷回归） ───────────────

  describe "转换副本形态回归（稀疏列位 / 数值手机 / 日期序号 / 匹配 key）" do
    alias Cgc2046.Flashback.Import.Xlsx

    test "稀疏 cell 按 r 属性列位展开——缺列补空，不整体左移错位" do
      {:ok, sheets} =
        build_xlsx([{"S", [["A", "B", "C"], ["1", "2", {:skip, 1}, "4"]]}])
        |> Xlsx.read()

      assert sheets["S"] == [["A", "B", "C"], ["1", "2", "", "4"]]
    end

    test "数值 cell 文本化读取（数值手机/日期序号的载体）" do
      {:ok, sheets} =
        build_xlsx([
          {"S", [["手机号", "提交时间"], [{:num, "1.3800138E10"}, {:num, "41643.375"}]]}
        ])
        |> Xlsx.read()

      assert sheets["S"] == [["手机号", "提交时间"], ["1.3800138E10", "41643.375"]]
    end

    test "数值形态手机归一：科学计数/浮点尾/+86/分隔符 → 11 位；12 位落警告" do
      sheet = [
        @header,
        [
          "赵科学",
          "女",
          "北京",
          {:num, "1.3800138000E10"},
          "zhao@example.com",
          "学生",
          "Mac",
          "自我介绍甲。",
          "",
          "有意思甲。",
          "2014-01-03T13:06:11+08:00"
        ],
        [
          "钱浮点",
          "女",
          "北京",
          {:num, "13800138002.0"},
          "",
          "学生",
          "Mac",
          "自我介绍乙。",
          "",
          "有意思乙。",
          "2014-01-03T13:06:11+08:00"
        ],
        [
          "孙国冠",
          "女",
          "北京",
          "+8613800138003",
          "",
          "学生",
          "Mac",
          "自我介绍丙。",
          "",
          "有意思丙。",
          "2014-01-03T13:06:11+08:00"
        ],
        [
          "李横线",
          "女",
          "北京",
          "186-0000-0004",
          "",
          "学生",
          "Mac",
          "自我介绍丁。",
          "",
          "有意思丁。",
          "2014-01-03T13:06:11+08:00"
        ],
        [
          "周十二位",
          "女",
          "北京",
          "152302007977",
          "",
          "学生",
          "Mac",
          "自我介绍戊。",
          "",
          "有意思戊。",
          "2014-01-03T13:06:11+08:00"
        ]
      ]

      admission = [
        ["姓名", "城市", "手机号"],
        ["赵科学", "北京", "13800138000"],
        ["钱浮点", "北京", "13800138002"],
        ["孙国冠", "北京", "13800138003"],
        ["李横线", "北京", "18600000004"]
      ]

      {:ok, report, _counts} =
        Import.run(build_xlsx([{"Sheet1", sheet}, {"学生", admission}]), dry_run: false)

      # 数值/前缀/分隔符形态全部归一 11 位；12 位不可归一 → 警告而非静默空
      assert report.contact_coverage.phone_unmappable == [{6, "152302007977"}]

      people = people_of_archive()
      assert phone_of(people, "赵科学") == "13800138000"
      assert phone_of(people, "钱浮点") == "13800138002"
      assert phone_of(people, "孙国冠") == "13800138003"
      assert phone_of(people, "李横线") == "18600000004"
      # 12 位原值保留（触达数据不丢），但不参与 phone key
      assert phone_of(people, "周十二位") == "152302007977"

      # 数值手机（归一后）与名单文本手机命中同一 {:phone, key} → attended；
      # 周十二位未入名单，走 name_city 兜底未命中 → not_selected
      assert report.participation == %{attended: 4, not_selected: 1}
    end

    test "Excel 1900 日期序号 → UTC：假闰日偏移 + 东八区语义，与 ISO 等值" do
      sheet = [
        @header,
        [
          "王序号",
          "女",
          "北京",
          "13900000001",
          "wx@example.com",
          "学生",
          "Mac",
          "自我介绍。",
          "",
          "有意思。",
          {:num, "41643.375"}
        ],
        [
          "李文本",
          "女",
          "北京",
          "13900000002",
          "",
          "学生",
          "Mac",
          "自我介绍。",
          "",
          "有意思。",
          "2014-01-04T09:00:00+08:00"
        ]
      ]

      admission = [["姓名", "城市", "手机号"], []]

      {:ok, report, _counts} =
        Import.run(build_xlsx([{"Sheet1", sheet}, {"学生", admission}]), dry_run: false)

      assert report.applied_at.parsed_iso == 1
      assert report.applied_at.parsed_serial == 1
      assert report.applied_at.failed == []

      # 41643.375 = 2014-01-04 09:00 东八区墙钟 → UTC 01:00，与 ISO 行等值
      people = people_of_archive()
      assert applied_at_of(people, "王序号") == ~U[2014-01-04 01:00:00.000000Z]
      assert applied_at_of(people, "李文本") == ~U[2014-01-04 01:00:00.000000Z]
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

    test "EventArchive 幂等 + 人员去重（重跑不建重复场次；重复人员跳过）" do
      {:ok, _r, _c} = Import.run(fixture_xlsx(), dry_run: false)
      {:ok, report2, counts2} = Import.run(fixture_xlsx(), dry_run: false)

      assert count_archives("2014-01-11-bj") == 1
      assert report2.existing_people_in_archive == 3
      assert report2.duplicates_vs_existing == 3
      # 全部 3 行都与已有重复 → 零插入、零升级（同 participation）
      assert counts2.people == 0
      assert counts2.upgraded == 0
    end

    test "Excel 内重复：同 key 多行只建第一行，dry-run 报告 duplicates_in_excel" do
      xlsx = fixture_xlsx_with_duplicate_row()
      {:ok, report, counts} = Import.run(xlsx, dry_run: false)

      assert report.duplicates_in_excel == 1
      assert counts.people == 3

      people = people_of_archive()
      assert length(people) == 3
    end

    test "participation 升级：已有 not_selected、新行 attended → 仅升级 participation" do
      # 第一次导入：王小明不在录取名单（not_selected）
      {:ok, _r1, _c1} = Import.run(fixture_xlsx_without_wang_in_admission(), dry_run: false)

      wang_before =
        people_of_archive()
        |> Enum.find(&(&1.full_name == "王小明"))

      assert wang_before.participation == :not_selected

      # 第二次导入：修正后的录取名单含王小明（attended）
      xlsx_fixed = fixture_xlsx_with_fixed_admission()
      {:ok, report2, counts2} = Import.run(xlsx_fixed, dry_run: false)

      assert report2.duplicates_to_upgrade == 2
      assert counts2.upgraded == 2
      assert counts2.people == 0

      wang_after =
        people_of_archive()
        |> Enum.find(&(&1.full_name == "王小明"))

      assert wang_after.participation == :attended
      # 其他字段不动（phone/email/city 等）
      assert wang_after.phone == wang_before.phone
    end

    test "反例：已有 not_selected、新行不在录取名单 → 不升级，participation 保持 not_selected" do
      # 第一次导入：王小明不在录取名单（not_selected）
      {:ok, _r1, _c1} = Import.run(fixture_xlsx_without_wang_in_admission(), dry_run: false)

      wang_before =
        people_of_archive()
        |> Enum.find(&(&1.full_name == "王小明"))

      assert wang_before.participation == :not_selected

      # 第二次导入：标准 fixture（录取名单含王小明+李雷，但王小明已在库里是 not_selected）
      # 新 Excel 里王小明在 Sheet1（会匹配已有），但他在录取名单里 → attended → 升级
      # 反例：韩梅梅在 Sheet1（会匹配已有），但她**不在**录取名单 → 不升级
      {:ok, report2, counts2} = Import.run(fixture_xlsx(), dry_run: false)

      # 韩梅梅：已有 not_selected、新行不在录取名单 → 不升级
      han_after =
        people_of_archive()
        |> Enum.find(&(&1.full_name == "韩梅梅"))

      assert han_after.participation == :not_selected

      # 王小明：已有 not_selected、新行在录取名单 → 升级
      wang_after =
        people_of_archive()
        |> Enum.find(&(&1.full_name == "王小明"))

      assert wang_after.participation == :attended

      # 升级计数 = 1（只有王小明）
      assert report2.duplicates_to_upgrade == 1
      assert counts2.upgraded == 1
    end
  end

  # ── 内部 ─────────────────────────────────────────────────────────────

  defp people_of_archive do
    archive = get_archive!("2014-01-11-bj")

    Flashback.Person
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(archive_event_id == ^archive.id)
    |> Ash.read!(authorize?: false)
  end

  defp phone_of(people, name) do
    people |> Enum.find(&(&1.full_name == name)) |> Map.get(:phone)
  end

  defp applied_at_of(people, name) do
    people |> Enum.find(&(&1.full_name == name)) |> Map.get(:applied_at)
  end

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
