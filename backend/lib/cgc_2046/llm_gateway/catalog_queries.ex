defmodule Cgc2046.LlmGateway.CatalogQueries do
  @moduledoc """
  `ProviderCatalog` 的运行时与读面查询、ETS 缓存及候选槽位解析。
  """

  import Ecto.Query

  alias Cgc2046.LlmGateway.CatalogValidation, as: V
  alias Cgc2046.LlmGateway.SecretBox
  alias Cgc2046.Repo

  @cache_table :llm_gateway_catalog_cache
  @cache_ttl_ms 30_000

  @doc """
  幂等初始化目录缓存 ETS 表。
  """
  def ensure_cache_table! do
    if :ets.whereis(@cache_table) == :undefined do
      :ets.new(@cache_table, [
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
  清空目录缓存；任何目录管理写操作后自动调用。
  """
  def invalidate_cache! do
    if :ets.whereis(@cache_table) != :undefined do
      :ets.delete_all_objects(@cache_table)
    end

    :ok
  end

  @doc """
  返回当前网关对外暴露的全部可用模型（仅包含启用的 Provider + 启用 Key + 启用模型，
  按 Provider priority 升序去重，仅含用户侧展示与售价信息）。
  """
  def list_available_models do
    cached_fetch(:available_models, fn ->
      query =
        from(m in "llm_provider_models",
          join: p in "llm_providers",
          as: :provider,
          on: m.provider_id == p.id,
          where: p.enabled == true and m.enabled == true,
          where:
            exists(
              from(k in "llm_provider_api_keys",
                where: k.provider_id == parent_as(:provider).id and k.enabled == true,
                select: 1
              )
            ),
          order_by: [asc: p.priority, asc: m.inserted_at],
          select: %{
            model_id: m.model_id,
            display_name: m.display_name,
            context_window: m.context_window,
            max_output_tokens: m.max_output_tokens,
            supports_thinking: m.supports_thinking,
            supports_tools: m.supports_tools,
            supports_images: m.supports_images,
            reasoning_efforts: m.reasoning_efforts,
            cache_hit_price_mc: m.cache_hit_price_mc,
            cache_miss_price_mc: m.cache_miss_price_mc,
            output_price_mc: m.output_price_mc,
            markup_ratio: m.markup_ratio
          }
        )

      {models, _seen} =
        Repo.all(query)
        |> Enum.reduce({[], MapSet.new()}, fn row, {acc, seen} ->
          if MapSet.member?(seen, row.model_id) do
            {acc, seen}
          else
            item = %{
              model_id: row.model_id,
              display_name: row.display_name,
              context_window: row.context_window,
              max_output_tokens: row.max_output_tokens,
              supports_thinking: row.supports_thinking,
              supports_tools: row.supports_tools,
              supports_images: row.supports_images,
              reasoning_efforts: row.reasoning_efforts || [],
              input_price_mc: round(row.cache_miss_price_mc * row.markup_ratio),
              cache_hit_price_mc: round(row.cache_hit_price_mc * row.markup_ratio),
              output_price_mc: round(row.output_price_mc * row.markup_ratio)
            }

            {[item | acc], MapSet.put(seen, row.model_id)}
          end
        end)

      Enum.reverse(models)
    end)
  end

  @doc """
  是否存在至少一个可用渠道（启用 Provider + 启用 Key + 启用模型）。
  """
  def has_any_active_channel? do
    cached_fetch(:any_active_channel, fn ->
      list_available_models() != []
    end)
  end

  @doc """
  解析指定 `model_id` 的全部可用上游槽位（每个启用的 Key 为一个槽位，按 Provider priority 排序）。
  """
  def resolve_candidates_for_model(model_id) when is_binary(model_id) do
    trimmed = String.trim(model_id)

    if trimmed == "" do
      []
    else
      cached_fetch({:candidates, trimmed}, fn -> load_candidates_for_model(trimmed) end)
    end
  end

  def resolve_candidates_for_model(_), do: []

  defp load_candidates_for_model(model_id) do
    query =
      from(m in "llm_provider_models",
        join: p in "llm_providers",
        on: m.provider_id == p.id,
        join: k in "llm_provider_api_keys",
        on: k.provider_id == p.id,
        where:
          m.model_id == ^model_id and m.enabled == true and p.enabled == true and
            k.enabled == true,
        order_by: [asc: p.priority, asc: p.inserted_at, asc: k.inserted_at],
        select: %{
          provider_id: type(p.id, Ecto.UUID),
          provider_slug: p.slug,
          protocol: p.protocol,
          base_url: p.base_url,
          chat_path: p.chat_path,
          priority: p.priority,
          off_peak_discount_enabled: p.off_peak_discount_enabled,
          key_id: type(k.id, Ecto.UUID),
          encrypted_api_key: k.encrypted_api_key,
          model_id: m.model_id,
          upstream_model_id: m.upstream_model_id,
          context_window: m.context_window,
          max_output_tokens: m.max_output_tokens,
          supports_thinking: m.supports_thinking,
          supports_tools: m.supports_tools,
          supports_images: m.supports_images,
          reasoning_efforts: m.reasoning_efforts,
          cache_hit_price_mc: m.cache_hit_price_mc,
          cache_miss_price_mc: m.cache_miss_price_mc,
          output_price_mc: m.output_price_mc,
          markup_ratio: m.markup_ratio
        }
      )

    Repo.all(query)
    |> Enum.flat_map(fn row ->
      case SecretBox.decrypt(row.encrypted_api_key) do
        {:ok, plaintext_key} ->
          [
            %{
              id: "#{row.provider_slug}:#{row.key_id}",
              channel_label: row.provider_slug,
              provider_id: row.provider_id,
              provider_slug: row.provider_slug,
              protocol: V.parse_protocol_atom(row.protocol),
              base_url: row.base_url,
              chat_path: row.chat_path,
              api_key: plaintext_key,
              priority: row.priority,
              off_peak_discount_enabled: row.off_peak_discount_enabled,
              model_id: row.model_id,
              upstream_model_id: row.upstream_model_id,
              context_window: row.context_window,
              max_output_tokens: row.max_output_tokens,
              supports_thinking: row.supports_thinking,
              supports_tools: row.supports_tools,
              supports_images: row.supports_images,
              reasoning_efforts: row.reasoning_efforts || [],
              pricing: %{
                cache_hit_mc: row.cache_hit_price_mc,
                cache_miss_mc: row.cache_miss_price_mc,
                output_mc: row.output_price_mc,
                markup_ratio: row.markup_ratio
              }
            }
          ]

        {:error, :decryption_failed} ->
          []
      end
    end)
  end

  defp cached_fetch(key, loader) do
    if Application.get_env(:cgc_2046, :llm_gateway_catalog_cache_enabled, true) do
      ensure_cache_table!()
      now = System.monotonic_time(:millisecond)

      case :ets.lookup(@cache_table, key) do
        [{^key, value, expires_at}] when expires_at > now ->
          value

        _ ->
          value = loader.()
          :ets.insert(@cache_table, {key, value, now + @cache_ttl_ms})
          value
      end
    else
      loader.()
    end
  end
end
