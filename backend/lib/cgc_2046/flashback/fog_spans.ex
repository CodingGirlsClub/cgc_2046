defmodule Cgc2046.Flashback.FogSpans do
  @moduledoc """
  雾面区间（KTD4）的结构校验单源：当年答案原文不可变，对外渲染按区间遮蔽，
  本人视图永显原文。

  区间坐标约定：**Unicode grapheme 偏移**（`String.length/1` 口径，非字节、非
  UTF-16 code unit）。Elixir grapheme 与 JavaScript 的 code point 迭代在 BMP
  内一致；emoji 组合序列按 Elixir 规范化口径计数。前端渲染与 U3 的离线标记
  语法解析（`docs/运维/闪念间雾化标记语法.md`）共用本约定。

  span 形状：`%{"start" => 非负整数, "len" => 正整数, "reason" => 可选文本}`
  （Ash `:map` 输入层是字符串键；原子键宽容接受——导入脚本内部构造）。

  校验规则（全部 fail-closed）：

  1. 结构：start/len 必须是整数，start >= 0，len > 0；reason 若给出必须是文本；
  2. 有序不重叠：按 start 排序后，`start(n+1) >= start(n) + len(n)`；
  3. 越界：`start + len <= String.length(text)`（text 为 nil 时跳过边界校验，
     由调用方在拿得到原文的层补齐）。
  """

  @type span :: %{optional(String.t()) => term()}

  @doc """
  校验区间列表；合法返回 `{:ok, spans}`（规范化为字符串键 map 列表），
  非法返回 `{:error, reason}`（原子，供调用方拼 InvalidAttribute 文案）。
  """
  @spec validate(term(), String.t() | nil) :: {:ok, [span()]} | {:error, atom()}
  def validate(spans, text \\ nil) do
    if is_list(spans) or is_nil(spans) do
      spans = List.wrap(spans)

      with {:ok, normalized} <- normalize(spans, []),
           :ok <- check_overlap(normalized),
           :ok <- check_bounds(normalized, text) do
        {:ok, normalized}
      end
    else
      {:error, :not_a_list}
    end
  end

  @doc """
  对外遮蔽视图（KTD3/KTD4）：按已验证区间把 fog 段替换为 `placeholder`，
  返回拼接文本（原文字符不出现）。区间未经验证时先走 `validate/2`——
  失败按全遮蔽处理（fail-closed，宁过度保护不泄露）。
  """
  @spec mask(String.t(), span() | nil, String.t()) :: String.t()
  def mask(text, spans, placeholder) when is_binary(text) do
    case validate(spans, text) do
      {:ok, normalized} ->
        normalized
        |> Enum.sort_by(&field(&1, :start))
        |> Enum.reduce({[], 0}, fn span, {acc, cursor} ->
          start = field(span, :start)
          len = field(span, :len)

          if start < cursor do
            # 重叠区间：跳过（validate 已挡，防御兜底）
            {acc, cursor}
          else
            {[String.slice(text, cursor, start - cursor), placeholder | acc], start + len}
          end
        end)
        |> then(fn {acc, cursor} ->
          tail = String.slice(text, cursor..-1//1)
          Enum.reverse([tail | acc])
        end)
        |> IO.iodata_to_binary()

      {:error, _} ->
        placeholder
    end
  end

  def mask(nil, _spans, placeholder), do: placeholder

  @doc """
  对外遮蔽段结构（U 雾化视觉升级）：按已验证区间把原文切成段列表
  `[%{text, fog, len}]`——fog 段 `text` 为空字符串（**原文字符不出现**，
  前端渲染为纯视觉雾块，长度按 `len` 提示档位）。校验失败按全雾
  fail-closed（同 `mask/3` 语义）。
  """
  @spec segments(String.t() | nil, span() | nil) :: [map()]
  def segments(text, spans) when is_binary(text) do
    case validate(spans, text) do
      {:ok, normalized} ->
        {acc, cursor} =
          Enum.reduce(Enum.sort_by(normalized, &field(&1, :start)), {[], 0}, fn span,
                                                                                {acc, cursor} ->
            start = field(span, :start)
            len = field(span, :len)
            head = String.slice(text, cursor, max(start - cursor, 0))
            {acc |> append_plain(head) |> append_fog(len), start + len}
          end)

        append_plain(acc, String.slice(text, cursor..-1//1))

      {:error, _} ->
        [%{text: "", fog: true, len: String.length(text)}]
    end
  end

  def segments(nil, _spans), do: []

  defp append_plain(acc, ""), do: acc

  defp append_plain(acc, text), do: [%{text: text, fog: false, len: 0} | acc]

  defp append_fog(acc, len) when len > 0, do: [%{text: "", fog: true, len: len} | acc]

  defp append_fog(acc, _len), do: acc

  defp normalize([], acc), do: {:ok, Enum.reverse(acc)}

  defp normalize([span | rest], acc) do
    with {:ok, map} <- coerce_map(span),
         start when is_integer(start) and start >= 0 <- field(map, :start),
         len when is_integer(len) and len > 0 <- field(map, :len),
         :ok <- coerce_reason(map) do
      span = %{"start" => start, "len" => len}

      span =
        case Map.get(map, "reason") || Map.get(map, :reason) do
          nil -> span
          reason -> Map.put(span, "reason", reason)
        end

      normalize(rest, [span | acc])
    else
      {:error, _} = err -> err
      _ -> {:error, :invalid_span}
    end
  end

  defp coerce_map(span) when is_map(span), do: {:ok, span}
  defp coerce_map(_), do: {:error, :invalid_span}

  # 字符串键（GraphQL/Ash :map 输入）与原子键（导入脚本内部构造）都收；
  # key 是本模块字面量原子，不做动态 String.to_atom/1。
  defp field(map, key) do
    case Map.get(map, Atom.to_string(key)) || Map.get(map, key) do
      nil -> {:error, :invalid_span}
      value -> value
    end
  end

  defp coerce_reason(map) do
    case Map.get(map, "reason") || Map.get(map, :reason) do
      nil -> :ok
      reason when is_binary(reason) -> :ok
      _ -> {:error, :invalid_reason}
    end
  end

  defp check_overlap(spans) do
    spans
    |> Enum.sort_by(& &1["start"])
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> b["start"] >= a["start"] + a["len"] end)
    |> if(do: :ok, else: {:error, :overlapping_spans})
  end

  defp check_bounds(_spans, nil), do: :ok

  defp check_bounds(spans, text) do
    limit = String.length(text)

    if Enum.all?(spans, &(&1["start"] + &1["len"] <= limit)) do
      :ok
    else
      {:error, :span_out_of_bounds}
    end
  end
end
