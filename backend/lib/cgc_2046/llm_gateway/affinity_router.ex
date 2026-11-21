defmodule Cgc2046.LlmGateway.AffinityRouter do
  @moduledoc """
  基于 DB `ProviderCatalog` 的模型感知粘性路由与 `:fuse` 熔断器管理。

  - 按请求的 `model_id` 从 `ProviderCatalog` 查询支持该模型的可用渠道槽位；
  - 同 `priority` 优先级层内基于 `(session_id | user_id, model_id)` 做会话粘性；
  - 渠道连续失败触发 `:fuse` 熔断后，在未向客户端发送首包前无缝漂移到同层下一槽位或更高优先数备用渠道。
  """

  alias Cgc2046.LlmGateway.Protocol.AnthropicAdapter
  alias Cgc2046.LlmGateway.Protocol.OpenaiAdapter
  alias Cgc2046.LlmGateway.ProviderCatalog

  @ets_table :llm_session_affinity
  @affinity_ttl_seconds 7_200

  @doc """
  初始化 ETS 会话粘性表；幂等。
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
  为渠道槽位安装熔断器：10 秒内 3 次失败即熔断，60 秒后自动恢复。
  """
  def install_fuse(channel_id) when is_binary(channel_id) do
    name = fuse_name(channel_id)

    case :fuse.ask(name, :sync) do
      {:error, :not_found} ->
        _ = :fuse.install(name, {{:standard, 3, 10_000}, {:reset, 60_000}})
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  为指定的 `requested_model` 解析按优先级与粘性排序的候选渠道。
  - 返回 `{:ok, [primary | rest]}`；
  - 目录内有其他可用模型但无该模型时返回 `{:error, :model_not_found}`；
  - 整个目录无可用渠道时返回 `{:error, :no_channels}`。
  """
  def candidate_channels(user_id, session_id, requested_model)
      when is_binary(requested_model) do
    setup!()

    case ProviderCatalog.resolve_candidates_for_model(requested_model) do
      [] ->
        if ProviderCatalog.has_any_active_channel?() do
          {:error, :model_not_found}
        else
          {:error, :no_channels}
        end

      all_channels ->
        Enum.each(all_channels, &install_fuse(&1.id))
        healthy = Enum.filter(all_channels, &channel_healthy?(&1.id))
        pool = if healthy == [], do: all_channels, else: healthy

        affinity_key =
          case session_id do
            bin when is_binary(bin) and byte_size(bin) > 0 ->
              "session:#{bin}:#{requested_model}"

            _ ->
              "user:#{user_id}:#{requested_model}"
          end

        now = System.system_time(:second)
        primary = resolve_sticky_primary(affinity_key, pool, now)
        {:ok, [primary | Enum.reject(pool, &(&1.id == primary.id))]}
    end
  end

  def candidate_channels(_user_id, _session_id, _requested_model), do: {:error, :model_not_found}

  @doc """
  按渠道协议构造上游 HTTP 请求（URL、Headers、协议转换后 Body）。
  """
  def build_upstream_request(params, channel) when is_map(params) and is_map(channel) do
    case Map.get(channel, :protocol, :openai_compatible) do
      :anthropic -> AnthropicAdapter.build_request(params, channel)
      _ -> OpenaiAdapter.build_request(params, channel)
    end
  end

  @doc """
  记录一次可重试的上游失败（401/403/429/5xx/网络错误），喂给熔断器。
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
    min_priority = pool |> Enum.map(&Map.get(&1, :priority, 100)) |> Enum.min()
    primary_tier = Enum.filter(pool, &(Map.get(&1, :priority, 100) == min_priority))

    idx = :erlang.phash2(affinity_key, length(primary_tier))
    chosen = Enum.at(primary_tier, idx)

    :ets.insert(@ets_table, {affinity_key, chosen.id, now + @affinity_ttl_seconds})
    chosen
  end

  defp fuse_name(channel_id), do: {:llm_fuse, channel_id}
end
