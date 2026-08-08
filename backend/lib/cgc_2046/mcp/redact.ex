defmodule Cgc2046.Mcp.Redact do
  @moduledoc """
  MCP 审计参数脱敏（D-D8）：落 ToolCallLog / PendingOperation 前过滤敏感键。

  规则：
  - 键名（大小写不敏感）命中敏感词列表 → 值替换为 "[REDACTED]"
  - 匹配方式：精确相等、`_xxx` 后缀（snake_case）、`Xxx` 后缀（camelCase，如 apiToken）
  - 嵌套 map / list 递归处理
  - 非 map 输入原样返回
  """
  @sensitive_keys ~w(token password secret authorization auth bearer api_key apikey
                   access_token refresh_token plain_token token_hash)

  @spec call(term()) :: term()
  def call(params) when is_map(params) do
    Map.new(params, fn {k, v} -> {k, redact_kv(k, v)} end)
  end

  def call(params) when is_list(params), do: Enum.map(params, &call/1)
  def call(other), do: other

  defp redact_kv(key, value) do
    if sensitive_key?(key) do
      "[REDACTED]"
    else
      call(value)
    end
  end

  defp sensitive_key?(key) do
    raw = to_string(key)
    normalized = String.downcase(raw)

    Enum.any?(@sensitive_keys, fn sensitive ->
      # camelCase 边界：apiToken → 拆分后尾部 "token" 命中
      camel_tail? = camel_tail_match?(raw, sensitive)

      normalized == sensitive or String.ends_with?(normalized, "_#{sensitive}") or camel_tail?
    end)
  end

  # raw 以 <CapitalizedSensitive> 结尾且前一个字符是小写字母 → camelCase 后缀命中
  # （避免 "Token" 全大写开头的正常键误伤，也避免 "monkey" 这类纯小写词误命中）
  defp camel_tail_match?(raw, sensitive) do
    cap = String.capitalize(sensitive)

    if String.ends_with?(raw, cap) do
      prefix = binary_part(raw, 0, byte_size(raw) - byte_size(cap))

      case prefix do
        "" -> false
        _ -> :binary.last(prefix) in ?a..?z
      end
    else
      false
    end
  end
end
