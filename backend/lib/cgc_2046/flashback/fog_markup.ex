defmodule Cgc2046.Flashback.FogMarkup do
  @moduledoc """
  雾面标记语法解析（R16a/KTD4）：离线 agent 在平台外对导入文本打的标记，
  由导入脚本（U3）解析为 `raw_text + fog_spans`——原文剥离全部标记符入库，
  区间为 grapheme 偏移（`String.length/1` 口径，与 `FogSpans` 同约定）。

  语法（全文见 `docs/运维/闪念间雾化标记语法.md`，离线 agent 与本解析器共用）：

      普通文本⟦这段雾掉⟧普通文本⟦这段也雾|雇主名⟧普通文本

  - 定界符：`⟦`（U+27E6）/ `⟧`（U+27E7），数学白方括号——2012-2018 年报名
    自由文本的实际字符集（手机/邮件/论坛风中文）中不出现，杜绝歧义。
  - 可选 reason：标记内**第一个** `|` 之后的内容（自由文本，可再含 `|`），
    只存进 span，不进 raw_text。
  - 转义：标记内外一致——`⟦⟦` 输出字面 `⟦`，`⟧⟧` 输出字面 `⟧`。
  - fail-closed：未闭合 / 嵌套（标记内再遇单个 `⟦`）/ 空区间 → 错误，
    由 dry-run 报告行级呈现，绝不静默丢字。

  返回 `{:ok, raw_text, spans}`，spans 为字符串键 map 列表
  （`%{"start" => int, "len" => int, "reason" => str?}`，与存储形态一致）；
  解析结果可直接经 `FogSpans.validate/2` 复核（结构/重叠/越界单源校验）。
  """

  @open "⟦"
  @close "⟧"
  @sep "|"

  @type span :: %{optional(String.t()) => term()}

  @spec parse(binary()) :: {:ok, binary(), [span()]} | {:error, atom()}
  def parse(text) when is_binary(text) do
    text
    |> String.graphemes()
    |> walk_outside([], [], 0)
  end

  # ── 标记外：累积输出；⟦⟦/⟧⟧ 转义、⟦ 进入标记 ────────────────────────

  defp walk_outside([@open, @open | rest], out, spans, pos) do
    walk_outside(rest, [@open | out], spans, pos + 1)
  end

  # 标记外的 ⟧⟧ 同样折叠为字面 ⟧（转义规则标记内外一致，见语法文档）。
  defp walk_outside([@close, @close | rest], out, spans, pos) do
    walk_outside(rest, [@close | out], spans, pos + 1)
  end

  # ⟦⟧（空标记）：len 0 非法，fail-closed 报错（区分于转义 ⟦⟦）。
  defp walk_outside([@open, @close | _rest], _out, _spans, _pos) do
    {:error, :empty_span}
  end

  defp walk_outside([@open | rest], out, spans, pos) do
    walk_inside(rest, out, spans, pos, [])
  end

  defp walk_outside([g | rest], out, spans, pos) do
    walk_outside(rest, [g | out], spans, pos + 1)
  end

  defp walk_outside([], out, spans, _pos) do
    {:ok, out |> Enum.reverse() |> IO.iodata_to_binary(), Enum.reverse(spans)}
  end

  # ── 标记内：累积雾面内容；⟧⟧ 转义、⟧ 闭合、单个 ⟦ 嵌套报错 ──────────

  defp walk_inside([@close, @close | rest], out, spans, pos, buf) do
    walk_inside(rest, out, spans, pos, [@close | buf])
  end

  defp walk_inside([@open, @open | rest], out, spans, pos, buf) do
    walk_inside(rest, out, spans, pos, [@open | buf])
  end

  defp walk_inside([@open | _rest], _out, _spans, _pos, _buf) do
    {:error, :nested_marker}
  end

  defp walk_inside([@close | rest], out, spans, pos, buf) do
    # 标记内第一个 `|` 分隔 reason：其前为内容（进 raw_text，KTD4 本人视图
    # 永远完整——fog 只是对外渲染遮蔽），其后仅存进 span 不进 raw_text。
    {body_rev, reason} = split_reason_from_buf(buf)
    len = length(body_rev)

    if len == 0 do
      {:error, :empty_span}
    else
      span =
        %{"start" => pos, "len" => len}
        |> maybe_reason(reason)

      # out 与 buf 均为倒序累积，直接拼接。
      walk_outside(rest, body_rev ++ out, [span | spans], pos + len)
    end
  end

  defp walk_inside([g | rest], out, spans, pos, buf) do
    walk_inside(rest, out, spans, pos, [g | buf])
  end

  defp walk_inside([], _out, _spans, _pos, _buf) do
    {:error, :unclosed_marker}
  end

  # 语义按正序：标记内第一个 `|` 分隔（其后可再含 `|`）。buf 为倒序，
  # 转正序切分后回转，正确性优先于单次遍历。
  defp split_reason_from_buf(buf) do
    case buf |> Enum.reverse() |> Enum.split_while(&(&1 != @sep)) do
      {_body_fwd, []} -> {buf, nil}
      {body_fwd, [_ | reason_fwd]} -> {Enum.reverse(body_fwd), Enum.join(reason_fwd)}
    end
  end

  defp maybe_reason(span, nil), do: span
  defp maybe_reason(span, ""), do: span
  defp maybe_reason(span, reason), do: Map.put(span, "reason", reason)
end
