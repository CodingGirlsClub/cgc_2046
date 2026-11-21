defmodule Cgc2046.LlmGateway.PricingPresets do
  @moduledoc """
  主流大模型参考单价（微积分 / 1M Tokens，1 CNY = 1,000,000 mc）与能力预设。

  供管理员在 Web 后台勾选或手动添加模型时自动预填，管理员可随时覆盖保存。
  """

  @presets [
    %{
      model_id: "deepseek-chat",
      display_name: "DeepSeek Chat",
      context_window: 128_000,
      max_output_tokens: 8_192,
      supports_thinking: false,
      supports_tools: true,
      supports_images: false,
      reasoning_efforts: [],
      cache_hit_price_mc: 200_000,
      cache_miss_price_mc: 2_000_000,
      output_price_mc: 3_000_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "deepseek-reasoner",
      display_name: "DeepSeek Reasoner",
      context_window: 128_000,
      max_output_tokens: 32_768,
      supports_thinking: true,
      supports_tools: true,
      supports_images: false,
      reasoning_efforts: ["low", "high", "max"],
      cache_hit_price_mc: 1_000_000,
      cache_miss_price_mc: 4_000_000,
      output_price_mc: 16_000_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "deepseek-flash",
      display_name: "DeepSeek Flash",
      context_window: 1_000_000,
      max_output_tokens: 32_768,
      supports_thinking: true,
      supports_tools: true,
      supports_images: true,
      reasoning_efforts: ["low", "high", "max"],
      cache_hit_price_mc: 100_000,
      cache_miss_price_mc: 1_000_000,
      output_price_mc: 2_000_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "deepseek-v4-pro",
      display_name: "DeepSeek V4 Pro",
      context_window: 1_000_000,
      max_output_tokens: 32_768,
      supports_thinking: true,
      supports_tools: true,
      supports_images: false,
      reasoning_efforts: ["low", "high", "max"],
      cache_hit_price_mc: 1_000_000,
      cache_miss_price_mc: 4_000_000,
      output_price_mc: 16_000_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "claude-sonnet-4-5",
      display_name: "Claude Sonnet 4.5",
      context_window: 200_000,
      max_output_tokens: 16_384,
      supports_thinking: true,
      supports_tools: true,
      supports_images: true,
      reasoning_efforts: ["low", "medium", "high"],
      cache_hit_price_mc: 2_160_000,
      cache_miss_price_mc: 21_600_000,
      output_price_mc: 108_000_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "claude-sonnet-4",
      display_name: "Claude Sonnet 4",
      context_window: 200_000,
      max_output_tokens: 16_384,
      supports_thinking: true,
      supports_tools: true,
      supports_images: true,
      reasoning_efforts: ["low", "medium", "high"],
      cache_hit_price_mc: 2_160_000,
      cache_miss_price_mc: 21_600_000,
      output_price_mc: 108_000_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "claude-opus-4-1",
      display_name: "Claude Opus 4.1",
      context_window: 200_000,
      max_output_tokens: 16_384,
      supports_thinking: true,
      supports_tools: true,
      supports_images: true,
      reasoning_efforts: ["low", "medium", "high", "max"],
      cache_hit_price_mc: 10_800_000,
      cache_miss_price_mc: 108_000_000,
      output_price_mc: 540_000_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "claude-haiku-4-5",
      display_name: "Claude Haiku 4.5",
      context_window: 200_000,
      max_output_tokens: 8_192,
      supports_thinking: false,
      supports_tools: true,
      supports_images: true,
      reasoning_efforts: [],
      cache_hit_price_mc: 720_000,
      cache_miss_price_mc: 7_200_000,
      output_price_mc: 36_000_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "claude-3-7-sonnet",
      display_name: "Claude 3.7 Sonnet",
      context_window: 200_000,
      max_output_tokens: 16_384,
      supports_thinking: true,
      supports_tools: true,
      supports_images: true,
      reasoning_efforts: ["low", "medium", "high"],
      cache_hit_price_mc: 2_160_000,
      cache_miss_price_mc: 21_600_000,
      output_price_mc: 108_000_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "claude-3-5-sonnet",
      display_name: "Claude 3.5 Sonnet",
      context_window: 200_000,
      max_output_tokens: 8_192,
      supports_thinking: false,
      supports_tools: true,
      supports_images: true,
      reasoning_efforts: [],
      cache_hit_price_mc: 2_160_000,
      cache_miss_price_mc: 21_600_000,
      output_price_mc: 108_000_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "claude-3-5-haiku",
      display_name: "Claude 3.5 Haiku",
      context_window: 200_000,
      max_output_tokens: 8_192,
      supports_thinking: false,
      supports_tools: true,
      supports_images: true,
      reasoning_efforts: [],
      cache_hit_price_mc: 580_000,
      cache_miss_price_mc: 5_800_000,
      output_price_mc: 29_000_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "gpt-4.1",
      display_name: "GPT-4.1",
      context_window: 1_047_576,
      max_output_tokens: 32_768,
      supports_thinking: false,
      supports_tools: true,
      supports_images: true,
      reasoning_efforts: [],
      cache_hit_price_mc: 3_600_000,
      cache_miss_price_mc: 14_400_000,
      output_price_mc: 57_600_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "gpt-4.1-mini",
      display_name: "GPT-4.1 Mini",
      context_window: 1_047_576,
      max_output_tokens: 32_768,
      supports_thinking: false,
      supports_tools: true,
      supports_images: true,
      reasoning_efforts: [],
      cache_hit_price_mc: 720_000,
      cache_miss_price_mc: 2_880_000,
      output_price_mc: 11_520_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "gpt-4o",
      display_name: "GPT-4o",
      context_window: 128_000,
      max_output_tokens: 16_384,
      supports_thinking: false,
      supports_tools: true,
      supports_images: true,
      reasoning_efforts: [],
      cache_hit_price_mc: 9_000_000,
      cache_miss_price_mc: 18_000_000,
      output_price_mc: 72_000_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "gpt-4o-mini",
      display_name: "GPT-4o Mini",
      context_window: 128_000,
      max_output_tokens: 16_384,
      supports_thinking: false,
      supports_tools: true,
      supports_images: true,
      reasoning_efforts: [],
      cache_hit_price_mc: 540_000,
      cache_miss_price_mc: 1_080_000,
      output_price_mc: 4_320_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "o3",
      display_name: "OpenAI o3",
      context_window: 200_000,
      max_output_tokens: 32_768,
      supports_thinking: true,
      supports_tools: true,
      supports_images: true,
      reasoning_efforts: ["low", "medium", "high"],
      cache_hit_price_mc: 3_600_000,
      cache_miss_price_mc: 14_400_000,
      output_price_mc: 57_600_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "o4-mini",
      display_name: "OpenAI o4-mini",
      context_window: 200_000,
      max_output_tokens: 32_768,
      supports_thinking: true,
      supports_tools: true,
      supports_images: true,
      reasoning_efforts: ["low", "medium", "high"],
      cache_hit_price_mc: 2_000_000,
      cache_miss_price_mc: 7_920_000,
      output_price_mc: 31_680_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "kimi-k2",
      display_name: "Kimi K2",
      context_window: 128_000,
      max_output_tokens: 16_384,
      supports_thinking: false,
      supports_tools: true,
      supports_images: false,
      reasoning_efforts: [],
      cache_hit_price_mc: 1_000_000,
      cache_miss_price_mc: 4_000_000,
      output_price_mc: 16_000_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "kimi-k2.5",
      display_name: "Kimi K2.5",
      context_window: 256_000,
      max_output_tokens: 32_768,
      supports_thinking: true,
      supports_tools: true,
      supports_images: true,
      reasoning_efforts: ["low", "high"],
      cache_hit_price_mc: 1_000_000,
      cache_miss_price_mc: 4_000_000,
      output_price_mc: 21_000_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "kimi-k3",
      display_name: "Kimi K3",
      context_window: 256_000,
      max_output_tokens: 32_768,
      supports_thinking: true,
      supports_tools: true,
      supports_images: false,
      reasoning_efforts: ["low", "high", "max"],
      cache_hit_price_mc: 1_000_000,
      cache_miss_price_mc: 4_000_000,
      output_price_mc: 16_000_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "kimi-k3.1-pro",
      display_name: "Kimi K3.1 Pro",
      context_window: 256_000,
      max_output_tokens: 32_768,
      supports_thinking: true,
      supports_tools: true,
      supports_images: false,
      reasoning_efforts: ["low", "high", "max"],
      cache_hit_price_mc: 2_000_000,
      cache_miss_price_mc: 8_000_000,
      output_price_mc: 32_000_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "MiniMax-M2.5",
      display_name: "MiniMax M2.5",
      context_window: 204_800,
      max_output_tokens: 32_768,
      supports_thinking: true,
      supports_tools: true,
      supports_images: false,
      reasoning_efforts: ["low", "medium", "high"],
      cache_hit_price_mc: 220_000,
      cache_miss_price_mc: 2_100_000,
      output_price_mc: 8_400_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "MiniMax-M3",
      display_name: "MiniMax M3",
      context_window: 256_000,
      max_output_tokens: 32_768,
      supports_thinking: true,
      supports_tools: true,
      supports_images: false,
      reasoning_efforts: [],
      cache_hit_price_mc: 300_000,
      cache_miss_price_mc: 2_400_000,
      output_price_mc: 9_600_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "MiniMax-M3.1-Flash",
      display_name: "MiniMax M3.1 Flash",
      context_window: 256_000,
      max_output_tokens: 32_768,
      supports_thinking: true,
      supports_tools: true,
      supports_images: false,
      reasoning_efforts: ["low", "medium", "high", "xhigh", "max"],
      cache_hit_price_mc: 200_000,
      cache_miss_price_mc: 1_500_000,
      output_price_mc: 6_000_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "qwen-max",
      display_name: "Qwen Max",
      context_window: 128_000,
      max_output_tokens: 8_192,
      supports_thinking: false,
      supports_tools: true,
      supports_images: false,
      reasoning_efforts: [],
      cache_hit_price_mc: 480_000,
      cache_miss_price_mc: 2_400_000,
      output_price_mc: 9_600_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "qwen-plus",
      display_name: "Qwen Plus",
      context_window: 128_000,
      max_output_tokens: 8_192,
      supports_thinking: true,
      supports_tools: true,
      supports_images: false,
      reasoning_efforts: ["low", "high"],
      cache_hit_price_mc: 160_000,
      cache_miss_price_mc: 800_000,
      output_price_mc: 2_000_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "qwen-turbo",
      display_name: "Qwen Turbo",
      context_window: 1_000_000,
      max_output_tokens: 8_192,
      supports_thinking: false,
      supports_tools: true,
      supports_images: false,
      reasoning_efforts: [],
      cache_hit_price_mc: 60_000,
      cache_miss_price_mc: 300_000,
      output_price_mc: 600_000,
      markup_ratio: 1.5
    },
    %{
      model_id: "qwq-32b",
      display_name: "QwQ 32B",
      context_window: 128_000,
      max_output_tokens: 16_384,
      supports_thinking: true,
      supports_tools: true,
      supports_images: false,
      reasoning_efforts: [],
      cache_hit_price_mc: 400_000,
      cache_miss_price_mc: 2_000_000,
      output_price_mc: 6_000_000,
      markup_ratio: 1.5
    }
  ]

  @presets_by_lower Map.new(@presets, fn preset ->
                      {String.downcase(preset.model_id), preset}
                    end)

  @sorted_prefixes @presets
                   |> Enum.sort_by(&String.length(&1.model_id), :desc)

  @spec list_presets() :: [map()]
  def list_presets, do: @presets

  @spec lookup(String.t()) :: {:ok, map()} | :error
  def lookup(model_id) when is_binary(model_id) do
    normalized =
      model_id
      |> String.trim()
      |> strip_provider_prefix()
      |> String.downcase()

    if normalized == "" do
      :error
    else
      case Map.fetch(@presets_by_lower, normalized) do
        {:ok, preset} ->
          {:ok, preset}

        :error ->
          stripped_date = Regex.replace(~r/-(?:\d{8}|\d{4}-\d{2}-\d{2})$/, normalized, "")

          case Map.fetch(@presets_by_lower, stripped_date) do
            {:ok, preset} ->
              {:ok, preset}

            :error ->
              find_prefix_preset(stripped_date)
          end
      end
    end
  end

  def lookup(_), do: :error

  defp strip_provider_prefix(id) do
    case String.split(id, "/", parts: 2) do
      [_vendor, rest] when rest != "" -> rest
      _ -> id
    end
  end

  defp find_prefix_preset(normalized) do
    Enum.find_value(@sorted_prefixes, :error, fn preset ->
      candidate = String.downcase(preset.model_id)

      if normalized == candidate or
           String.starts_with?(normalized, candidate <> "-") or
           String.starts_with?(normalized, candidate <> ":") do
        {:ok, preset}
      end
    end)
  end
end
