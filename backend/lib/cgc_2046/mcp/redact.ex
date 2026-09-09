defmodule Cgc2046.Mcp.Redact do
  @moduledoc """
  MCP 审计参数脱敏（D-D8；role-agent-journeys-v2 S8 增 per-tool 白名单）：
  落 ToolCallLog 审计行前过滤敏感键。**只作用于审计路径**——PendingOperation.params
  是确认流事务数据（confirm 时原样执行），落完整参数，不经本模块（见
  `Cgc2046.Mcp.Confirmation.request/4`）。

  规则（按序应用）：
  1. **敏感键脱敏（全部工具）**：键名（大小写不敏感）命中敏感词列表 → 值
     替换为 "[REDACTED]"；匹配方式：精确相等、`_xxx` 后缀（snake_case）、
     `Xxx` 后缀（camelCase，如 apiToken）；嵌套 map / list 递归处理。
  2. **按工具收窄（S8，R48/AE12）**：`submit_learning_attempt` 落库 params
     只留操作引用字段 `workspace_id / course_id / objective_id / passed /
     confidence`——evidence / rubric_results / rationale / agent_meta
     **不落审计**（证据正文结构化存储在 Attempt 账本行，审计行按操作引用；
     AE12：ToolCallLog 永不持证据/rubric 明细/判定理由）。其他工具原样通过。
  3. **字节上限（P2 防审计放大）**：单字符串值超 `@max_value_bytes` → 替换为
     截断元数据 `%{"truncated" => true, "byte_size" => 原值字节数, "preview" => 前
     @preview_bytes 字节}`（截断存证，不落完整内容）；整条 params JSON 超
     `@max_params_bytes` → 整体退化为 `metadata_only/1` 摘要。被拒绝（forbidden）
     的调用由 Wrapper 进一步降为 `metadata_only/1`——只保留必要元数据（参数键、
     小标量、长度、截断标记），不落值内容。

  `call/1` 为默认路径（工具无关，规则 1 + 3）；`call/2` 带工具名应用规则 2。
  """
  @sensitive_keys ~w(token password secret authorization auth bearer api_key apikey
                   access_token refresh_token plain_token token_hash)

  # submit_learning_attempt 审计白名单（S8）：审计 = 操作引用，证据正文归
  # Attempt 账本（AE12——ToolCallLog 永不持证据/rubric 明细/判定理由）
  @learning_attempt_audit_keys ~w(workspace_id course_id objective_id passed confidence)

  # P2 防审计放大：大体积参数（如 4MB 字符串）即使被权限拒绝也曾完整落审计，
  # 约 250 次调用即可产生 1GB 逻辑参数量。上限取审计存证够用量级——单值 1KB、
  # 整条 8KB（对照：error_message 摘要截断 500 字符）。
  @max_value_bytes 1_024
  @preview_bytes 256
  @max_params_bytes 8_192

  # metadata_only 保留的小标量阈值：workspace_id（UUID 36 字节）等查询锚必须原样
  # 保留——admin 审计列表与 my_workspace_tool_calls 均按 params->>'workspace_id'
  # 过滤，替换为元数据会让既有审计查询静默漏行（回归）。
  @scalar_keep_bytes 64

  # metadata_only 输出的键数上限：键名本身也可放大（攻击者造数千个键），
  # 截断存证须对自身有界
  @max_metadata_keys 50

  @spec call(term()) :: term()
  def call(params), do: call(nil, params)

  @spec call(String.t() | nil, term()) :: term()
  def call(tool_name, params) when is_map(params) do
    params
    |> Map.new(fn {k, v} -> {k, redact_kv(k, v)} end)
    |> narrow_for_tool(tool_name)
    |> cap_total_bytes()
  end

  def call(_tool_name, params) when is_list(params), do: Enum.map(params, &call/1)
  def call(_tool_name, params) when is_binary(params), do: cap_string(params)
  def call(_tool_name, other), do: other

  @doc """
  截断元数据摘要（P2）：被拒绝（forbidden）调用的审计 params 只保留必要
  元数据——参数键、小标量（<= #{@scalar_keep_bytes} 字节的字符串 / 数字 /
  布尔 / nil，查询锚如 workspace_id 得以保留）、大值的长度与截断标记，
  不落值内容。

  输入须为已经 `call/2` 脱敏的 params（敏感键已替换为 "[REDACTED]"，
  10 字节小标量原样保留，不会再泄露）。
  """
  @spec metadata_only(map()) :: map()
  def metadata_only(params) when is_map(params) do
    total = map_size(params)

    kept =
      params
      |> Enum.take(@max_metadata_keys)
      |> Map.new(fn {k, v} -> {cap_key(k), metadata_value(v)} end)

    if total > @max_metadata_keys do
      Map.put(kept, "_dropped_keys", total - @max_metadata_keys)
    else
      kept
    end
  end

  # 小标量原样保留（workspace_id 等 JSONB 查询锚）；其余只留长度与截断标记
  defp metadata_value(value) when is_binary(value) do
    if byte_size(value) <= @scalar_keep_bytes do
      value
    else
      %{"truncated" => true, "byte_size" => byte_size(value)}
    end
  end

  defp metadata_value(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: value

  # 已经 call/2 截断的标记 map：保留原值长度、丢弃 preview（拒绝请求不落内容）；
  # 必须先于下方兜底子句，否则标记 map 被二次测量（原长度丢失）
  defp metadata_value(%{"truncated" => true, "byte_size" => n}) when is_integer(n),
    do: %{"truncated" => true, "byte_size" => n}

  defp metadata_value(value), do: %{"truncated" => true, "byte_size" => term_bytes(value)}

  # 键名同样有界（攻击者可控）；to_string 统一键形（审计落 JSONB 本就会字符串化）
  defp cap_key(key) do
    s = to_string(key)

    if byte_size(s) <= @scalar_keep_bytes do
      s
    else
      byte_prefix(s, @scalar_keep_bytes) <> "…"
    end
  end

  # ---- 规则 3：字节上限（P2 防审计放大）----

  defp cap_string(value) when byte_size(value) <= @max_value_bytes, do: value

  defp cap_string(value) do
    %{
      "truncated" => true,
      "byte_size" => byte_size(value),
      "preview" => byte_prefix(value, @preview_bytes)
    }
  end

  # 整条 params JSON 超上限 → 整体退化为截断元数据摘要（多键 / 嵌套放大兜底）
  defp cap_total_bytes(params) do
    if term_bytes(params) <= @max_params_bytes, do: params, else: metadata_only(params)
  end

  defp term_bytes(value) when is_binary(value), do: byte_size(value)

  defp term_bytes(value) do
    case Jason.encode(value) do
      {:ok, json} -> byte_size(json)
      {:error, _} -> byte_size(inspect(value))
    end
  end

  # 按字节截前缀并回退到 UTF-8 边界（binary_part 可能切断多字节字符，
  # 非法 UTF-8 会让 JSONB 落库失败）
  defp byte_prefix(bin, max_bytes) do
    bin
    |> binary_part(0, max_bytes)
    |> trim_to_valid_utf8()
  end

  defp trim_to_valid_utf8(bin) do
    if String.valid?(bin) do
      bin
    else
      trim_to_valid_utf8(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end

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
