defmodule Cgc2046.Flashback.Import.Xlsx do
  @moduledoc """
  最小 xlsx 读取器（U3，KTD11 零新依赖）：`:zip`（OTP 内置）+ `saxy`
  （既有依赖，MIT）——xlsx 即 ZIP + XML，无需引入 Excel 解析库。

  只做导入脚本需要的子集：sheet 名 → 行×列字符串矩阵。

  - sharedStrings（含 rich text 多 `<t>` run 拼接）、inlineStr、数字/文本 cell；
  - 稀疏 cell（如 `r="C5"` 前缺 A5/B5）按列字母展开补空；
  - 只读值，不处理公式/样式/日期序列号（2014 场时间戳为 ISO8601 文本，
    R22 已核；其他形态由 dry-run 报告暴露）。

  ## fail-closed 格式判定（R22：扩展名与真实格式在本批数据已错位）

  - `PK\x03\x04` → xlsx，正常解析；
  - OLE2 magic `D0 CF 11 E0`（BIFF8 .xls）→ `{:error, {:biff8, hint}}`，
    hint 为给操作者的转换指引（Excel/LibreOffice 另存或
    `soffice --convert-to xlsx`）；
  - 其余 → `{:error, :unsupported_format}`。
  """

  @biff8_hint "先用 Excel/LibreOffice 另存为 .xlsx（或 soffice --convert-to xlsx）后重试"

  @type sheets :: %{String.t() => [[String.t()]]}

  @doc "读 xlsx 字节流 → %{sheet_name => 行×列字符串矩阵}（首行即表头，原样返回）。"
  @spec read(binary()) :: {:ok, sheets()} | {:error, term()}
  def read(binary) when is_binary(binary) do
    with :ok <- check_format(binary),
         {:ok, entries} <- unzip(binary),
         files = Map.new(entries),
         {:ok, sheet_names} <- workbook_sheets(files),
         shared <- shared_strings(files) do
      sheets =
        sheet_names
        |> Enum.with_index(1)
        |> Map.new(fn {{name, rid}, idx} ->
          target = sheet_target(files, rid, idx)
          {name, sheet_matrix(files, target, shared)}
        end)

      {:ok, sheets}
    end
  end

  defp check_format(<<"PK", _::binary>>), do: :ok

  defp check_format(<<0xD0, 0xCF, 0x11, 0xE0, _::binary>>),
    do: {:error, {:biff8, @biff8_hint}}

  defp check_format(_), do: {:error, :unsupported_format}

  defp unzip(binary) do
    case :zip.extract(binary, [:memory]) do
      # OTP :zip memory 模式返回 charlist 路径；统一转 binary 键。
      {:ok, entries} ->
        {:ok, Enum.map(entries, fn {path, content} -> {IO.chardata_to_string(path), content} end)}

      {:error, reason} ->
        {:error, {:bad_zip, reason}}
    end
  end

  # ── XML（saxy SimpleForm：{"tag", attrs, children}，文本节点为 binary）──

  defp xml(path, files) do
    case Map.fetch(files, path) do
      {:ok, bin} -> Saxy.SimpleForm.parse_string(bin)
      :error -> {:error, {:missing_entry, path}}
    end
  end

  defp children_of({_, _, children}, tag), do: Enum.filter(children, &match?({^tag, _, _}, &1))

  defp attr({_, attrs, _}, key), do: List.keyfind(attrs, key, 0) |> then(&if(&1, do: elem(&1, 1)))

  defp text_content({_, _, children}) do
    children
    |> Enum.filter(&is_binary/1)
    |> IO.iodata_to_binary()
  end

  # workbook.xml：<sheet name="…" r:id="rId1"/>；rels 映射 rId → worksheets/sheetN.xml。
  # 返回 [{name, rid}]——sheet 名与 target 的对应靠 rid 钉住（多 sheet 场景）。
  defp workbook_sheets(files) do
    with {:ok, wb} <- xml("xl/workbook.xml", files) do
      pairs =
        wb
        |> find_deep("sheets")
        |> children_of("sheet")
        |> Enum.map(fn sheet ->
          {attr(sheet, "name"), attr(sheet, "r:id") || attr(sheet, "id")}
        end)
        |> Enum.reject(fn {name, rid} -> is_nil(name) or is_nil(rid) end)

      {:ok, pairs}
    end
  end

  # 深度找一层包裹元素（sheets/si/row 等都可能在 document 元素直接子级）。
  defp find_deep({tag, _, _} = node, tag), do: node

  defp find_deep({_, _, children}, tag) do
    case Enum.find(children, &match?({^tag, _, _}, &1)) do
      nil -> {tag, [], []}
      found -> found
    end
  end

  defp sheet_target(files, rid, fallback_index) do
    with {:ok, rels} <- xml("xl/_rels/workbook.xml.rels", files) do
      rels
      |> children_of("Relationship")
      |> Enum.find_value(default_target(fallback_index), fn rel ->
        if attr(rel, "Id") == rid and (attr(rel, "Type") || "") =~ "worksheet" do
          target = attr(rel, "Target") || ""
          # rels target 相对 xl/（worksheets/sheet1.xml），也容忍绝对 /xl/…
          if String.starts_with?(target, "/") do
            String.trim_leading(target, "/")
          else
            "xl/" <> target
          end
        end
      end)
    end
  end

  defp default_target(index), do: "xl/worksheets/sheet#{index}.xml"

  # sharedStrings.xml：<si><t>a</t></si> 与富文本 <si><r><t>a</t><t>b</t></r></si>
  # 全部 <t> 拼接。
  defp shared_strings(files) do
    case Map.fetch(files, "xl/sharedStrings.xml") do
      {:ok, bin} ->
        {:ok, sst} = Saxy.SimpleForm.parse_string(bin)

        find_deep(sst, "sst")
        |> children_of("si")
        |> Enum.map(fn si ->
          si
          |> all_text()
          |> IO.iodata_to_binary()
        end)

      :error ->
        []
    end
  end

  defp all_text(node) do
    [text_content(node) | Enum.map(children(node), &all_text/1)]
  end

  defp children({_, _, children}), do: Enum.filter(children, &is_tuple/1)

  # sheet xml：行按 r 属性、cell 按 r="A1" 列字母展开；t="s" 索引 shared、
  # t="inlineStr" 取 <is><t>、缺省取 <v>。
  defp sheet_matrix(files, target, shared) do
    with {:ok, sheet} <- xml(target, files) do
      find_deep(sheet, "sheetData")
      |> children_of("row")
      |> Enum.map(fn row ->
        row
        |> children_of("c")
        |> Enum.map(fn cell ->
          ref = attr(cell, "ref") || ""
          {cell_value(cell, shared), col_index(ref)}
        end)
        |> expand_row()
      end)
    else
      _ -> []
    end
  end

  defp cell_value(cell, shared) do
    case attr(cell, "t") do
      "s" ->
        cell |> child_text("v") |> then(&fetch_shared(shared, &1))

      "inlineStr" ->
        cell |> find_deep_child("is") |> then(&all_text/1) |> IO.iodata_to_binary()

      _ ->
        child_text(cell, "v")
    end
  end

  defp child_text(cell, tag) do
    case Enum.find(children(cell), &match?({^tag, _, _}, &1)) do
      nil -> ""
      found -> text_content(found)
    end
  end

  defp find_deep_child(cell, tag) do
    case Enum.find(children(cell), &match?({^tag, _, _}, &1)) do
      nil -> {tag, [], []}
      found -> found
    end
  end

  defp fetch_shared(_shared, ""), do: ""

  defp fetch_shared(shared, index) do
    case Integer.parse(index) do
      {i, ""} -> Enum.at(shared, i, "")
      _ -> ""
    end
  end

  # "C5" → 2（0 基列号）；非法 ref 归 0。
  defp col_index(ref) do
    letters = ref |> String.split(" ") |> List.first("") |> String.replace(~r/\d/, "")

    letters
    |> String.upcase()
    |> String.to_charlist()
    |> Enum.reduce(0, fn ch, acc -> acc * 26 + (ch - ?A + 1) end)
    |> max(1)
    |> Kernel.-(1)
  end

  # 稀疏 cell 展开成连续行（缺位补 ""，尾随缺位自然短行——导入层按列名取值，
  # 短行无碍）。
  defp expand_row(cells) do
    cells
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.reduce({[], -1}, fn {value, col}, {acc, prev} ->
      pad = List.duplicate("", max(col - prev - 1, 0))
      {acc ++ pad ++ [value], max(col, prev)}
    end)
    |> elem(0)
  end
end
