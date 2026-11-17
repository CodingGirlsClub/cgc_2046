defmodule Cgc2046.LlmGateway.TokenizerAndPricing do
  @moduledoc """
  基于 `Tiktoken` 的精确 token 计数与双成本微积分计算
  （`upstream_cost_mc` vs 用户侧 `charged_mc`）。

  1 CNY = 1_000_000 Microcredits (mc)。正常完成优先使用上游 `usage`；
  客户端半途断流时用 Tiktoken 对已下发 content/reasoning 做估算兜底，
  防止断流免费。
  """

  # Tiktoken 的 encoding_for_model 只认模型名；gpt-4 映射到 cl100k_base，
  # 与 DeepSeek tokenizer 的 cl100k 口径一致。
  @tiktoken_model "gpt-4"
  @default_markup_ratio 1.5
  @default_hold_output_tokens 1024

  @pricing_per_million_tokens %{
    "deepseek-chat" => %{
      cache_hit_mc: 200_000,
      cache_miss_mc: 2_000_000,
      output_mc: 3_000_000
    },
    "deepseek-reasoner" => %{
      cache_hit_mc: 1_000_000,
      cache_miss_mc: 4_000_000,
      output_mc: 16_000_000
    }
  }

  @doc """
  精确统计文本 token 数；Tiktoken 不可用时按 3 字节/token 兜底。
  """
  def count_text_tokens(text) when is_binary(text) and byte_size(text) > 0 do
    case Tiktoken.count_tokens(@tiktoken_model, text) do
      {:ok, count} when is_integer(count) and count > 0 -> count
      count when is_integer(count) and count > 0 -> count
      _ -> max(1, div(byte_size(text), 3))
    end
  rescue
    _ -> max(1, div(byte_size(text), 3))
  end

  def count_text_tokens(_), do: 0

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
  def estimate_pre_flight_hold_mc(params, upstream_model) do
    prompt_tokens = count_request_prompt_tokens(params)
    rates = rates_for(upstream_model)

    raw_cost_mc =
      div(
        prompt_tokens * rates.cache_miss_mc +
          @default_hold_output_tokens * rates.output_mc,
        1_000_000
      )

    markup = Application.get_env(:cgc_2046, :llm_gateway_markup_ratio, @default_markup_ratio)
    max(100, round(raw_cost_mc * markup))
  end

  @doc """
  结算计算。上游 `usage` 存在 → 精确计费；nil → 断流估算；上游在产生
  token 前失败 → 全免。
  """
  def calculate_settlement(upstream_model, prompt_tokens, stream_state)
      when is_map(stream_state) do
    rates = rates_for(upstream_model)
    markup = Application.get_env(:cgc_2046, :llm_gateway_markup_ratio, @default_markup_ratio)

    case Map.get(stream_state, :official_usage) do
      usage when is_map(usage) ->
        {hit_tokens, miss_tokens, completion_tokens, reasoning_tokens} =
          extract_official_tokens(usage)

        upstream_cost_mc =
          div(
            hit_tokens * rates.cache_hit_mc +
              miss_tokens * rates.cache_miss_mc +
              completion_tokens * rates.output_mc,
            1_000_000
          )

        # 用户侧把 cache-hit 输入按 cache-miss 的一半计价，保留折扣但收回大部分缓存红利。
        user_input_cost_mc =
          div(
            hit_tokens * div(rates.cache_miss_mc, 2) +
              miss_tokens * rates.cache_miss_mc +
              completion_tokens * rates.output_mc,
            1_000_000
          )

        charged_mc = max(1, round(user_input_cost_mc * markup))

        %{
          billing_mode: :exact,
          prompt_cache_hit_tokens: hit_tokens,
          prompt_cache_miss_tokens: miss_tokens,
          completion_tokens: completion_tokens,
          reasoning_tokens: reasoning_tokens,
          upstream_cost_mc: max(1, upstream_cost_mc),
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
          upstream_cost_mc =
            div(
              prompt_tokens * rates.cache_miss_mc +
                total_completion_tokens * rates.output_mc,
              1_000_000
            )

          charged_mc = max(1, round(upstream_cost_mc * markup))

          %{
            billing_mode: :estimated_abort,
            prompt_cache_hit_tokens: 0,
            prompt_cache_miss_tokens: prompt_tokens,
            completion_tokens: total_completion_tokens,
            reasoning_tokens: est_reasoning_tokens,
            upstream_cost_mc: max(1, upstream_cost_mc),
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

  defp rates_for(upstream_model) when is_binary(upstream_model) do
    cond do
      Map.has_key?(@pricing_per_million_tokens, upstream_model) ->
        Map.fetch!(@pricing_per_million_tokens, upstream_model)

      String.contains?(upstream_model, "reasoner") or String.contains?(upstream_model, "-r1") ->
        @pricing_per_million_tokens["deepseek-reasoner"]

      true ->
        @pricing_per_million_tokens["deepseek-chat"]
    end
  end

  defp rates_for(_upstream_model), do: @pricing_per_million_tokens["deepseek-chat"]
end
