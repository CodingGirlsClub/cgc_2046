defmodule Cgc2046.Mcp.Redact do
  @moduledoc """
  MCP 审计参数脱敏（D-D8；role-agent-journeys-v2 S8 增 per-tool 白名单）：
  落 ToolCallLog / PendingOperation 前过滤敏感键。

  规则（按序应用）：
  1. **敏感键脱敏（全部工具）**：键名（大小写不敏感）命中敏感词列表 → 值
     替换为 "[REDACTED]"；匹配方式：精确相等、`_xxx` 后缀（snake_case）、
     `Xxx` 后缀（camelCase，如 apiToken）；嵌套 map / list 递归处理。
  2. **按工具收窄（S8，R48/AE12）**：`submit_learning_attempt` 落库 params
     只留操作引用字段 `workspace_id / course_id / objective_id / passed /
     confidence`——evidence / rubric_results / rationale / agent_meta
     **不落审计**（证据正文结构化存储在 Attempt 账本行，审计行按操作引用；
     AE12：ToolCallLog 永不持证据/rubric 明细/判定理由）。其他工具原样通过。

  `call/1` 为默认路径（工具无关，仅规则 1）；`call/2` 带工具名应用规则 2。
  """
  @sensitive_keys ~w(token password secret authorization auth bearer api_key apikey
                   access_token refresh_token plain_token token_hash)

  # submit_learning_attempt 审计白名单（S8）：审计 = 操作引用，证据正文归
  # Attempt 账本（AE12——ToolCallLog 永不持证据/rubric 明细/判定理由）
  @learning_attempt_audit_keys ~w(workspace_id course_id objective_id passed confidence)

  @spec call(term()) :: term()
  def call(params), do: call(nil, params)

  @spec call(String.t() | nil, term()) :: term()
  def call(tool_name, params) when is_map(params) do
    params
    |> Map.new(fn {k, v} -> {k, redact_kv(k, v)} end)
    |> narrow_for_tool(tool_name)
  end

  def call(_tool_name, params) when is_list(params), do: Enum.map(params, &call/1)
  def call(_tool_name, other), do: other

  defp redact_kv(key, value) do
    if sensitive_key?(key) do
      "[REDACTED]"
    else
      call(value)
    end
  end

  # 规则 2（S8）：submit_learning_attempt 的审计 params 收窄为操作引用白名单
  # （string / atom 键均兼容——生产路径经 Jason 解码为 string 键，直调/测试
  # 可能给 atom 键；保留原键形）；其他工具原样通过
  defp narrow_for_tool(params, "submit_learning_attempt") do
    Map.filter(params, fn {k, _v} -> to_string(k) in @learning_attempt_audit_keys end)
  end

  defp narrow_for_tool(params, _tool_name), do: params

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
