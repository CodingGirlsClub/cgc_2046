defmodule Cgc2046.LlmGateway.TokenizerAndPricing do
  @moduledoc """
  基于 `Tiktoken` 的精确 token 计数与双成本微积分计算
  （`upstream_cost_mc` vs 用户侧 `charged_mc`）。

  1 CNY = 1_000_000 Microcredits (mc)。正常完成优先使用上游 `usage`；
  客户端半途断流时用 Tiktoken 对已下发 content/reasoning 做估算兜底，
  防止断流免费。
  """

  require Logger

  # Tiktoken 的 encoding_for_model 只认模型名；gpt-4 映射到 cl100k_base，
  # 与 DeepSeek tokenizer 的 cl100k 口径一致。
  @tiktoken_model "gpt-4"
  @default_markup_ratio 1.5
  @default_hold_output_tokens 1_024
  @hold_output_cap_default 2_048
  @hold_output_cap_reasoning 4_096
  @hold_output_cap_background 1_024

  @default_pricing_per_million_tokens %{
    "deepseek-chat" => %{
      cache_hit_mc: 200_000,
      cache_miss_mc: 2_000_000,
      output_mc: 3_000_000
    },
    "deepseek-reasoner" => %{
      cache_hit_mc: 1_000_000,
      cache_miss_mc: 4_000_000,
      output_mc: 16_000_000
    },
    "deepseek-flash" => %{
      cache_hit_mc: 100_000,
      cache_miss_mc: 1_000_000,
      output_mc: 2_000_000
    },
    "deepseek-v4-pro" => %{
      cache_hit_mc: 1_000_000,
      cache_miss_mc: 4_000_000,
      output_mc: 16_000_000
    },
    "volcengine-deepseek-v3" => %{
      cache_hit_mc: 400_000,
      cache_miss_mc: 2_000_000,
      output_mc: 8_000_000
    },
    "volcengine-deepseek-r1" => %{
      cache_hit_mc: 1_000_000,
      cache_miss_mc: 4_000_000,
      output_mc: 16_000_000
    }
  }

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
  预授权冻结额：按 100% cache-miss prompt + 保守输出缓冲估算，再乘 markup。
  """
  def estimate_pre_flight_hold_mc(params, pricing_model) do
    prompt_tokens = count_request_prompt_tokens(params)
    estimate_pre_flight_hold_mc(params, pricing_model, prompt_tokens)
  end

  @doc """
  使用已算好的 `prompt_tokens` 估算预授权冻结额，避免重复分词。
  冻结输出缓冲与上游 `max_tokens` 解耦，按模型档位封顶以防长推理额度误伤正常余额用户。
  """
  def estimate_pre_flight_hold_mc(params, pricing_model, prompt_tokens)
      when is_integer(prompt_tokens) and prompt_tokens >= 0 do
    rates = rates_for(pricing_model)
    cap = hold_output_cap(params, pricing_model)

    requested_output_tokens =
      case Map.get(params, "max_tokens") do
        max_tokens when is_integer(max_tokens) and max_tokens > 0 ->
          max_tokens

        _ ->
          @default_hold_output_tokens
      end

    hold_output_tokens = min(requested_output_tokens, cap)

    raw_cost_mc =
      div(
        prompt_tokens * rates.cache_miss_mc +
          hold_output_tokens * rates.output_mc,
        1_000_000
      )

    markup = Application.get_env(:cgc_2046, :llm_gateway_markup_ratio, @default_markup_ratio)
    max(100, round(raw_cost_mc * markup))
  end

  @doc """
  计算上游通道的时段折扣倍率（仅作用于 `upstream_cost_mc`，用户计价 24/7 恒定）。

  DeepSeek 官方通道在 `:llm_gateway_off_peak_pricing_enabled` 开启（默认 `true`）时：
  周一至周五 01:00–04:00 UTC 与 06:00–10:00 UTC 为高峰（`1.0`），其余时段与周末为错峰（`0.5`）；
  其他厂商恒为 `1.0`。
  """
  def upstream_rate_multiplier(provider, now \\ DateTime.utc_now())

  def upstream_rate_multiplier(:deepseek, %DateTime{} = now) do
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

  def upstream_rate_multiplier(_provider, _now), do: 1.0

  @doc """
  结算计算。上游 `usage` 存在 → 精确计费；nil → 断流估算；上游在产生
  token 前失败 → 全免。
  """
  def calculate_settlement(pricing_model, prompt_tokens, stream_state)
      when is_map(stream_state) do
    rates = rates_for(pricing_model)
    markup = Application.get_env(:cgc_2046, :llm_gateway_markup_ratio, @default_markup_ratio)

    provider =
      Map.get(stream_state, :channel_provider) ||
        Map.get(stream_state, :provider) ||
        :deepseek

    settled_at = Map.get(stream_state, :settled_at) || DateTime.utc_now()
    upstream_multiplier = upstream_rate_multiplier(provider, settled_at)

    # SSE 200 错误帧优先于 usage：上游即便随错误帧附带 usage，失败流也一律免单。
    usage_or_error =
      if Map.get(stream_state, :sse_error?, false),
        do: :sse_error,
        else: Map.get(stream_state, :official_usage)

    case usage_or_error do
      :sse_error ->
        %{
          billing_mode: :waived_upstream_error,
          prompt_cache_hit_tokens: 0,
          prompt_cache_miss_tokens: 0,
          completion_tokens: 0,
          reasoning_tokens: 0,
          upstream_cost_mc: 0,
          charged_mc: 0
        }

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

        # 透明统一加价：用户侧按标准基准价 × markup 24/7 恒定计费（不叠加隐藏缓存加价），
        # 上游真实成本按通道错峰倍率记录以准确核算毛利。
        upstream_cost_mc = max(1, round(base_cost_mc * upstream_multiplier))
        charged_mc = max(1, round(base_cost_mc * markup))

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
          %{
            billing_mode: :waived_upstream_error,
            prompt_cache_hit_tokens: 0,
            prompt_cache_miss_tokens: 0,
            completion_tokens: 0,
            reasoning_tokens: 0,
            upstream_cost_mc: 0,
            charged_mc: 0
          }
        else
          # 客户端断流或上游中途失败：按 100% cache-miss prompt + 已生成 token 计费。
          base_cost_mc =
            div(
              prompt_tokens * rates.cache_miss_mc +
                total_completion_tokens * rates.output_mc,
              1_000_000
            )

          upstream_cost_mc = max(1, round(base_cost_mc * upstream_multiplier))
          charged_mc = max(1, round(base_cost_mc * markup))

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

  defp hold_output_cap(params, pricing_model) do
    model = Map.get(params, "model")

    cond do
      model == "cgc-background" or pricing_model == "deepseek-flash" ->
        @hold_output_cap_background

      reasoning_pricing_model?(pricing_model) ->
        @hold_output_cap_reasoning

      true ->
        @hold_output_cap_default
    end
  end

  defp reasoning_pricing_model?(pricing_model) when is_binary(pricing_model) do
    String.contains?(pricing_model, "reasoner") or
      String.contains?(pricing_model, "-r1") or
      String.contains?(pricing_model, "v4-pro")
  end

  defp reasoning_pricing_model?(_), do: false

  defp pricing_rates do
    case Application.get_env(:cgc_2046, :llm_gateway_pricing_rates) do
      overrides when is_map(overrides) ->
        Map.merge(@default_pricing_per_million_tokens, overrides)

      _ ->
        @default_pricing_per_million_tokens
    end
  end

  defp rates_for(pricing_model) when is_binary(pricing_model) do
    all_rates = pricing_rates()

    Map.get(
      all_rates,
      pricing_model,
      Map.fetch!(all_rates, "deepseek-chat")
    )
  end

  defp rates_for(_pricing_model), do: Map.fetch!(pricing_rates(), "deepseek-chat")
end
