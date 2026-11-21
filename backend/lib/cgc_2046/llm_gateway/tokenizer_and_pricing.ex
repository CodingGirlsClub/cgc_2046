defmodule Cgc2046.LlmGateway.TokenizerAndPricing do
  @moduledoc """
  基于 `Tiktoken` 的精确 token 计数与双成本微积分计算
  （`upstream_cost_mc` vs 用户侧 `charged_mc`）。

  1 CNY = 1_000_000 Microcredits (mc)。单价直接来自所选模型的数据库配置
  （`%{cache_hit_mc, cache_miss_mc, output_mc, markup_ratio}`）。
  正常完成优先使用上游 `usage`；客户端半途断流时用 Tiktoken 对已下发
  content/reasoning 做估算兜底，防止断流免费。
  """

  require Logger

  # Tiktoken 的 encoding_for_model 只认模型名；gpt-4 映射到 cl100k_base，
  # 与主流现代词表口径一致。
  @tiktoken_model "gpt-4"
  @default_markup_ratio 1.5
  @default_hold_output_tokens 1_024
  @hold_output_cap_default 2_048
  @hold_output_cap_reasoning 4_096

  @doc """
  启动或发布前烟雾校验：确认 `Tiktoken` NIF 正常加载且 `"hello world"` 返回精确 token 数 `2`。
  """
  def verify_tokenizer! do
    case Tiktoken.count_tokens(@tiktoken_model, "hello world") do
      {:ok, 2} ->
        :ok

      2 ->
        :ok

      other ->
        raise "Tiktoken tokenizer verification failed: expected 2 tokens for \"hello world\", got #{inspect(other)}"
    end
  end

  @doc """
  精确统计文本 token 数；Tiktoken 不可用时按 3 字节/token 兜底，并记录告警与遥测。
  """
  def count_text_tokens(text) when is_binary(text) and byte_size(text) > 0 do
    count_text_tokens_with_model(@tiktoken_model, text)
  end

  def count_text_tokens(_), do: 0

  @doc false
  def count_text_tokens_with_model(model, text)
      when is_binary(model) and is_binary(text) and byte_size(text) > 0 do
    case Tiktoken.count_tokens(model, text) do
      {:ok, count} when is_integer(count) and count > 0 ->
        count

      count when is_integer(count) and count > 0 ->
        count

      other ->
        emit_tokenizer_fallback(text, {:unexpected_return, other})
        max(1, div(byte_size(text), 3))
    end
  rescue
    exception ->
      emit_tokenizer_fallback(text, {:exception, exception.__struct__})
      max(1, div(byte_size(text), 3))
  end

  defp emit_tokenizer_fallback(text, reason) do
    byte_len = byte_size(text)

    Logger.warning(
      "llm gateway tiktoken fallback triggered: reason=#{inspect(reason)} byte_size=#{byte_len}"
    )

    :telemetry.execute(
      [:cgc2046, :llm_gateway, :tokenizer_fallback],
      %{byte_size: byte_len},
      %{reason: reason}
    )
  end

  @doc """
  统计 chat completion payload 中 messages + tools 的 prompt token 数。
  """
  def count_request_prompt_tokens(params) when is_map(params) do
    messages = params |> Map.get("messages", []) |> normalize_messages()

    messages_text =
      Enum.map_join(messages, "\n", fn msg ->
        content =
          case Map.get(msg, "content") do
            bin when is_binary(bin) -> bin
            list when is_list(list) -> Jason.encode!(list)
            _ -> ""
          end

        tool_calls =
          case Map.get(msg, "tool_calls") do
            nil -> ""
            tool_calls -> Jason.encode!(tool_calls)
          end

        "#{Map.get(msg, "role", "user")}: #{content} #{tool_calls}"
      end)

    tools_text =
      case Map.get(params, "tools") do
        nil -> ""
        [] -> ""
        tools -> Jason.encode!(tools)
      end

    msg_overhead = length(messages) * 4
    count_text_tokens(messages_text <> "\n" <> tools_text) + msg_overhead
  end

  def count_request_prompt_tokens(_), do: 0

  @doc """
  预授权冻结额：按 100% cache-miss prompt + 保守输出缓冲估算，再乘模型 markup。
  """
  def estimate_pre_flight_hold_mc(params, channel) when is_map(channel) do
    prompt_tokens = count_request_prompt_tokens(params)
    estimate_pre_flight_hold_mc(params, channel, prompt_tokens)
  end

  @doc """
  使用已算好的 `prompt_tokens` 估算预授权冻结额，避免重复分词。
  冻结输出缓冲与上游 `max_tokens` 解耦，按模型能力封顶以防长推理额度误伤正常余额用户。
  """
  def estimate_pre_flight_hold_mc(params, channel, prompt_tokens)
      when is_map(channel) and is_integer(prompt_tokens) and prompt_tokens >= 0 do
    rates = extract_pricing(channel)
    cap = hold_output_cap(channel)

    requested_output_tokens =
      Enum.find_value(
        ["max_tokens", "max_completion_tokens"],
        @default_hold_output_tokens,
        fn key ->
          case Map.get(params, key) do
            val when is_integer(val) and val > 0 -> val
            _ -> nil
          end
        end
      )

    hold_output_tokens = min(requested_output_tokens, cap)

    raw_cost_mc =
      div(
        prompt_tokens * rates.cache_miss_mc +
          hold_output_tokens * rates.output_mc,
        1_000_000
      )

    max(100, round(raw_cost_mc * rates.markup_ratio))
  end

  @doc """
  计算上游通道的时段折扣倍率（仅作用于 `upstream_cost_mc`，用户计价 24/7 恒定）。

  当 Provider 开启 `off_peak_discount_enabled` 且 `:llm_gateway_off_peak_pricing_enabled`
  开启（默认 `true`）时：周一至周五 01:00–04:00 UTC 与 06:00–10:00 UTC 为高峰（`1.0`），
  其余时段与周末为错峰（`0.5`）；未开启时恒为 `1.0`。
  """
  def upstream_rate_multiplier(off_peak_enabled?, now \\ DateTime.utc_now())

  def upstream_rate_multiplier(true, %DateTime{} = now) do
    if Application.get_env(:cgc_2046, :llm_gateway_off_peak_pricing_enabled, true) do
      utc = now |> DateTime.to_unix() |> DateTime.from_unix!()
      dow = utc |> DateTime.to_date() |> Date.day_of_week()
      hour = utc.hour

      if dow in 1..5 and (hour in 1..3 or hour in 6..9) do
        1.0
      else
        0.5
      end
    else
      1.0
    end
  end

  def upstream_rate_multiplier(_off_peak_enabled, _now), do: 1.0

  @doc """
  结算计算。上游 `usage` 存在 → 精确计费；nil → 断流估算；上游在产生
  token 前失败或 SSE 报错 → 全免。
  """
  def calculate_settlement(pricing_or_channel, prompt_tokens, stream_state)
      when is_map(pricing_or_channel) and is_map(stream_state) do
    rates = extract_pricing(pricing_or_channel)

    off_peak_enabled? = Map.get(stream_state, :off_peak_discount_enabled, false) == true
    settled_at = Map.get(stream_state, :settled_at) || DateTime.utc_now()
    upstream_multiplier = upstream_rate_multiplier(off_peak_enabled?, settled_at)

    usage_or_error =
      if Map.get(stream_state, :sse_error?, false),
        do: :sse_error,
        else: Map.get(stream_state, :official_usage)

    case usage_or_error do
      :sse_error ->
        waived_settlement()

      usage when is_map(usage) ->
        {hit_tokens, miss_tokens, completion_tokens, reasoning_tokens} =
          extract_official_tokens(usage)

        base_cost_mc =
          div(
            hit_tokens * rates.cache_hit_mc +
              miss_tokens * rates.cache_miss_mc +
              completion_tokens * rates.output_mc,
            1_000_000
          )

        {upstream_cost_mc, charged_mc} =
          finalize_amounts(base_cost_mc, rates, upstream_multiplier)

        %{
          billing_mode: :exact,
          prompt_cache_hit_tokens: hit_tokens,
          prompt_cache_miss_tokens: miss_tokens,
          completion_tokens: completion_tokens,
          reasoning_tokens: reasoning_tokens,
          upstream_cost_mc: upstream_cost_mc,
          charged_mc: charged_mc
        }

      _ ->
        output_text = iodata_to_binary(Map.get(stream_state, :output_iodata))
        reasoning_text = iodata_to_binary(Map.get(stream_state, :reasoning_iodata))

        est_output_tokens = count_text_tokens(output_text)
        est_reasoning_tokens = count_text_tokens(reasoning_text)
        total_completion_tokens = est_output_tokens + est_reasoning_tokens

        if total_completion_tokens == 0 and Map.get(stream_state, :upstream_error?, false) do
          waived_settlement()
        else
          base_cost_mc =
            div(
              prompt_tokens * rates.cache_miss_mc +
                total_completion_tokens * rates.output_mc,
              1_000_000
            )

          {upstream_cost_mc, charged_mc} =
            finalize_amounts(base_cost_mc, rates, upstream_multiplier)

          %{
            billing_mode: :estimated_abort,
            prompt_cache_hit_tokens: 0,
            prompt_cache_miss_tokens: prompt_tokens,
            completion_tokens: total_completion_tokens,
            reasoning_tokens: est_reasoning_tokens,
            upstream_cost_mc: upstream_cost_mc,
            charged_mc: charged_mc
          }
        end
    end
  end

  defp waived_settlement do
    %{
      billing_mode: :waived_upstream_error,
      prompt_cache_hit_tokens: 0,
      prompt_cache_miss_tokens: 0,
      completion_tokens: 0,
      reasoning_tokens: 0,
      upstream_cost_mc: 0,
      charged_mc: 0
    }
  end

  defp finalize_amounts(base_cost_mc, rates, upstream_multiplier) do
    if rates.cache_hit_mc == 0 and rates.cache_miss_mc == 0 and rates.output_mc == 0 do
      {0, 0}
    else
      upstream_cost_mc = max(1, round(base_cost_mc * upstream_multiplier))
      charged_mc = max(1, round(base_cost_mc * rates.markup_ratio))
      {upstream_cost_mc, charged_mc}
    end
  end

  defp extract_pricing(%{pricing: pricing}) when is_map(pricing), do: extract_pricing(pricing)

  defp extract_pricing(pricing) when is_map(pricing) do
    %{
      cache_hit_mc: Map.get(pricing, :cache_hit_mc, 0),
      cache_miss_mc: Map.get(pricing, :cache_miss_mc, 0),
      output_mc: Map.get(pricing, :output_mc, 0),
      markup_ratio: Map.get(pricing, :markup_ratio, @default_markup_ratio)
    }
  end

  defp hold_output_cap(channel) do
    cap =
      if Map.get(channel, :supports_thinking, false) do
        @hold_output_cap_reasoning
      else
        @hold_output_cap_default
      end

    case Map.get(channel, :max_output_tokens) do
      limit when is_integer(limit) and limit > 0 -> min(cap, limit)
      _ -> cap
    end
  end

  defp normalize_messages(messages) when is_list(messages) do
    Enum.filter(messages, &is_map/1)
  end

  defp normalize_messages(_), do: []

  defp iodata_to_binary(nil), do: ""
  defp iodata_to_binary(iodata) when is_binary(iodata), do: iodata
  defp iodata_to_binary(iodata) when is_list(iodata), do: IO.iodata_to_binary(iodata)
  defp iodata_to_binary(_), do: ""

  defp extract_official_tokens(usage) do
    prompt_total = Map.get(usage, "prompt_tokens", 0)

    hit =
      Map.get(usage, "prompt_cache_hit_tokens") ||
        get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
        0

    miss =
      Map.get(usage, "prompt_cache_miss_tokens") ||
        max(0, prompt_total - hit)

    completion = Map.get(usage, "completion_tokens", 0)

    reasoning =
      Map.get(usage, "reasoning_tokens") ||
        get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) ||
        0

    {hit, miss, completion, reasoning}
  end
end
