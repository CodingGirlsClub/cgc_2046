defmodule Cgc2046.LlmGateway.AffinityRouter do
  @moduledoc """
  Session-affinity 路由与 `:fuse` 熔断器管理。

  同一 `x-session-affinity`（或 `session_id`）始终优先命中同一上游渠道，
  以最大化 DeepSeek 的 KV 前缀缓存命中率；渠道连续失败触发 `:fuse` 熔断
  后，在未向客户端发送任何内容前无缝漂移到下一个候选渠道。
  """

  @ets_table :llm_session_affinity
  @affinity_ttl_seconds 7_200
  @max_output_tokens 8_192
  @default_output_tokens 4_096
  @background_output_tokens 1_024

  @default_channels [
    %{
      id: "deepseek_official_1",
      provider: :deepseek,
      base_url: "https://api.deepseek.com",
      api_key: "sk-dev-placeholder",
      chat_path: "/chat/completions",
      pricing_model: %{
        "cgc-default" => "deepseek-chat",
        "cgc-reasoning" => "deepseek-reasoner",
        "cgc-background" => "deepseek-chat"
      },
      models: %{
        "cgc-default" => "deepseek-chat",
        "cgc-reasoning" => "deepseek-reasoner",
        "cgc-background" => "deepseek-chat"
      }
    }
  ]

  @doc """
  初始化 ETS 会话粘性表并安装配置渠道的熔断器；幂等。
  """
  def setup! do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    Enum.each(configured_channels(), fn channel -> install_fuse(channel.id) end)
    :ok
  end

  @doc """
  删除已过期的会话粘性条目；由 `AffinityStore` 周期调用，测试可直接调用。
  """
  def cleanup_expired! do
    setup!()
    now = System.system_time(:second)

    :ets.select_delete(@ets_table, [
      {{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}
    ])

    :ok
  end

  @doc """
  为渠道安装熔断器：10 秒内 3 次失败即熔断，60 秒后自动恢复。
  """
  def install_fuse(channel_id) when is_binary(channel_id) do
    name = fuse_name(channel_id)

    # 已存在时不能重复 install：fuse 的 install 会 reset 计数，
    # 会让连续的 report_failure 永远攒不到熔断阈值。
    case :fuse.ask(name, :sync) do
      {:error, :not_found} ->
        _ = :fuse.install(name, {{:standard, 3, 10_000}, {:reset, 60_000}})
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  返回按优先级排列的候选渠道。首元素为粘性主渠道，其余为未发首包前的
  故障转移候选；配置为空时返回 `[]`（由 controller 返回 503）。
  """
  def candidate_channels(user_id, session_id) do
    setup!()

    case configured_channels() do
      [] ->
        []

      all_channels ->
        healthy = Enum.filter(all_channels, &channel_healthy?(&1.id))
        # 全部熔断时仍返回全量，让请求有机会触发恢复
        pool = if healthy == [], do: all_channels, else: healthy

        affinity_key =
          case session_id do
            bin when is_binary(bin) and byte_size(bin) > 0 -> "session:#{bin}"
            _ -> "user:#{user_id}"
          end

        now = System.system_time(:second)
        primary = resolve_sticky_primary(affinity_key, pool, now)
        [primary | Enum.reject(pool, &(&1.id == primary.id))]
    end
  end

  @doc """
  记录一次可重试的上游失败（429/5xx/网络错误），喂给熔断器。
  """
  def report_failure(channel_id) when is_binary(channel_id) do
    install_fuse(channel_id)
    _ = :fuse.melt(fuse_name(channel_id))
    :ok
  end

  @doc """
  渠道熔断器当前是否健康。
  """
  def channel_healthy?(channel_id) when is_binary(channel_id) do
    install_fuse(channel_id)

    case :fuse.ask(fuse_name(channel_id), :sync) do
      :ok -> true
      :blown -> false
      {:error, _} -> false
    end
  end

  @doc """
  把逻辑模型别名解析成渠道物理模型，并清洗该逻辑模型的冲突参数。
  返回 `{logical_model, upstream_model, payload}`。
  """
  def prepare_upstream_payload(params, channel) when is_map(params) and is_map(channel) do
    logical_model = Map.get(params, "model") || "cgc-default"
    models = Map.get(channel, :models, %{})

    upstream_model =
      Map.get(models, logical_model) ||
        Map.get(models, "cgc-default") ||
        "deepseek-chat"

    cleaned_params =
      params
      |> Map.put("model", upstream_model)
      |> Map.put("stream", true)
      |> Map.put("stream_options", %{"include_usage" => true})
      |> sanitize_for_logical_model(logical_model, upstream_model)

    {logical_model, upstream_model, cleaned_params}
  end

  @doc """
  拼接渠道的 OpenAI-compatible chat completions URL。
  """
  def chat_url(channel) when is_map(channel) do
    base_url =
      channel
      |> Map.get(:base_url, "")
      |> to_string()
      |> String.trim_trailing("/")

    path =
      channel
      |> Map.get(:chat_path, "/chat/completions")
      |> to_string()
      |> ensure_leading_slash()

    base_url <> path
  end

  @doc """
  返回渠道/逻辑模型对应的计费模型。渠道可显式配置 `pricing_model` 映射，
  避免从火山方舟 `ep-...` 这类不透明上游 ID 猜模型族。
  """
  def pricing_model(channel, logical_model) when is_map(channel) and is_binary(logical_model) do
    case get_in(channel, [:pricing_model, logical_model]) do
      model when is_binary(model) -> model
      _ -> default_pricing_model(logical_model)
    end
  end

  defp default_pricing_model("cgc-reasoning"), do: "deepseek-reasoner"
  defp default_pricing_model(_logical_model), do: "deepseek-chat"

  def configured_channels do
    case Application.get_env(:cgc_2046, :llm_gateway_channels, @default_channels) do
      channels when is_list(channels) -> channels
      _ -> @default_channels
    end
  end

  defp sanitize_for_logical_model(params, logical_model, upstream_model) do
    is_reasoner? =
      logical_model == "cgc-reasoning" or
        String.contains?(upstream_model, "reasoner") or
        String.contains?(upstream_model, "-r1")

    params =
      if is_reasoner? do
        Map.drop(params, [
          "temperature",
          "top_p",
          "presence_penalty",
          "frequency_penalty",
          "logprobs",
          "top_logprobs"
        ])
      else
        params
      end

    output_limit =
      case Map.get(params, "max_tokens") do
        max_tokens when is_integer(max_tokens) and max_tokens > 0 ->
          if logical_model == "cgc-background" do
            min(max_tokens, @background_output_tokens)
          else
            min(max_tokens, @max_output_tokens)
          end

        _ ->
          if logical_model == "cgc-background" do
            @background_output_tokens
          else
            @default_output_tokens
          end
      end

    Map.put(params, "max_tokens", output_limit)
  end

  defp resolve_sticky_primary(affinity_key, pool, now) do
    case :ets.lookup(@ets_table, affinity_key) do
      [{^affinity_key, bound_channel_id, expires_at}] when expires_at > now ->
        case Enum.find(pool, &(&1.id == bound_channel_id)) do
          nil -> bind_new_channel(affinity_key, pool, now)
          channel -> channel
        end

      [{^affinity_key, _bound_channel_id, _expires_at}] ->
        :ets.delete(@ets_table, affinity_key)
        bind_new_channel(affinity_key, pool, now)

      _ ->
        bind_new_channel(affinity_key, pool, now)
    end
  end

  defp bind_new_channel(affinity_key, pool, now) do
    primaries = Enum.reject(pool, &String.contains?(&1.id, "backup"))
    selection_pool = if primaries != [], do: primaries, else: pool

    idx = :erlang.phash2(affinity_key, length(selection_pool))
    chosen = Enum.at(selection_pool, idx)

    :ets.insert(@ets_table, {affinity_key, chosen.id, now + @affinity_ttl_seconds})
    chosen
  end

  defp ensure_leading_slash(path) do
    if String.starts_with?(path, "/"), do: path, else: "/" <> path
  end

  defp fuse_name(channel_id), do: :"llm_fuse_#{channel_id}"
end
