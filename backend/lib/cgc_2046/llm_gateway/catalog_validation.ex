defmodule Cgc2046.LlmGateway.CatalogValidation do
  @moduledoc """
  `ProviderCatalog` 的参数校验、错误归类与对外投影（不泄露加密密钥原文）。
  """

  alias Cgc2046.LlmGateway.UpstreamDiscovery

  @spec validate_provider_attrs(map(), :create | :update, map() | nil) ::
          {:ok, map()} | {:error, atom()}
  def validate_provider_attrs(attrs, mode, existing \\ nil) do
    name = map_get_with_fallback(attrs, :name, existing && existing.name) |> trim_or_empty()

    slug =
      map_get_with_fallback(attrs, :slug, existing && existing.slug)
      |> trim_or_empty()
      |> String.downcase()

    protocol_raw =
      map_get_with_fallback(
        attrs,
        :protocol,
        (existing && existing.protocol) || :openai_compatible
      )

    base_url_raw =
      map_get_with_fallback(attrs, :base_url, existing && existing.base_url) |> trim_or_empty()

    priority = map_get_with_fallback(attrs, :priority, (existing && existing.priority) || 100)

    chat_path =
      optional_trimmed(map_get_with_fallback(attrs, :chat_path, existing && existing.chat_path))

    models_path =
      optional_trimmed(
        map_get_with_fallback(attrs, :models_path, existing && existing.models_path)
      )

    off_peak =
      map_get_with_fallback(
        attrs,
        :off_peak_discount_enabled,
        (existing && existing.off_peak_discount_enabled) || false
      ) == true

    enabled =
      case mode do
        :create -> map_get(attrs, :enabled) != false
        :update -> map_get_with_fallback(attrs, :enabled, existing.enabled) == true
      end

    with true <- name != "" || {:error, :invalid_name},
         true <- Regex.match?(~r/^[a-z0-9][a-z0-9_-]{0,63}$/, slug) || {:error, :invalid_slug},
         {:ok, protocol} <- cast_protocol(protocol_raw),
         {:ok, base_url} <- UpstreamDiscovery.validate_base_url(base_url_raw),
         true <- (is_integer(priority) and priority >= 0) || {:error, :invalid_priority} do
      {:ok,
       %{
         name: name,
         slug: slug,
         protocol: protocol,
         base_url: base_url,
         chat_path: chat_path,
         models_path: models_path,
         priority: priority,
         off_peak_discount_enabled: off_peak,
         enabled: enabled
       }}
    else
      {:error, _} = err -> err
    end
  end

  @spec validate_key_update_attrs(map()) :: {:ok, map()} | {:error, atom()}
  def validate_key_update_attrs(attrs) do
    updates = %{}

    updates =
      case map_get(attrs, :label) do
        nil -> updates
        val when is_binary(val) -> Map.put(updates, :label, String.trim(val))
        _ -> Map.put(updates, :label, "")
      end

    updates =
      case map_get(attrs, :enabled) do
        val when is_boolean(val) -> Map.put(updates, :enabled, val)
        _ -> updates
      end

    if Map.get(updates, :label) == "" do
      {:error, :key_label_empty}
    else
      {:ok, updates}
    end
  end

  @spec validate_models_batch(list()) :: {:ok, [map()]} | {:error, atom()}
  def validate_models_batch(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, acc} ->
      case validate_model_attrs(attrs) do
        {:ok, validated} -> {:cont, {:ok, [validated | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      err -> err
    end
  end

  @spec validate_model_attrs(term()) :: {:ok, map()} | {:error, atom()}
  def validate_model_attrs(attrs) when is_map(attrs) do
    model_id = attrs |> map_get(:model_id) |> trim_or_empty()
    upstream_raw = attrs |> map_get(:upstream_model_id) |> trim_or_empty()
    upstream_model_id = if upstream_raw == "", do: model_id, else: upstream_raw
    display_raw = attrs |> map_get(:display_name) |> trim_or_empty()
    display_name = if display_raw == "", do: model_id, else: display_raw

    context_window = map_get(attrs, :context_window) || 128_000
    max_output_tokens = map_get(attrs, :max_output_tokens) || 8_192
    cache_hit = map_get(attrs, :cache_hit_price_mc) || 0
    cache_miss = map_get(attrs, :cache_miss_price_mc) || 0
    output_price = map_get(attrs, :output_price_mc) || 0
    markup = parse_markup(map_get(attrs, :markup_ratio))

    efforts =
      case map_get(attrs, :reasoning_efforts) do
        list when is_list(list) ->
          list |> Enum.map(&trim_or_empty/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

        _ ->
          []
      end

    valid? =
      model_id != "" and String.length(model_id) <= 128 and
        not String.contains?(model_id, "|") and
        upstream_model_id != "" and
        is_integer(context_window) and context_window > 0 and
        is_integer(max_output_tokens) and max_output_tokens > 0 and
        is_integer(cache_hit) and cache_hit >= 0 and
        is_integer(cache_miss) and cache_miss >= 0 and
        is_integer(output_price) and output_price >= 0 and
        is_float(markup) and markup >= 1.0

    if valid? do
      {:ok,
       %{
         model_id: model_id,
         upstream_model_id: upstream_model_id,
         display_name: display_name,
         enabled: map_get(attrs, :enabled) != false,
         context_window: context_window,
         max_output_tokens: max_output_tokens,
         supports_thinking: map_get(attrs, :supports_thinking) == true,
         supports_tools: map_get(attrs, :supports_tools) != false,
         supports_images: map_get(attrs, :supports_images) == true,
         reasoning_efforts: efforts,
         cache_hit_price_mc: cache_hit,
         cache_miss_price_mc: cache_miss,
         output_price_mc: output_price,
         markup_ratio: markup
       }}
    else
      {:error, :model_invalid}
    end
  end

  def validate_model_attrs(_), do: {:error, :model_invalid}

  def project_admin_provider(provider) do
    %{
      id: provider.id,
      name: provider.name,
      slug: provider.slug,
      protocol: to_string(provider.protocol),
      base_url: provider.base_url,
      chat_path: provider.chat_path,
      models_path: provider.models_path,
      priority: provider.priority,
      off_peak_discount_enabled: provider.off_peak_discount_enabled,
      enabled: provider.enabled,
      api_keys:
        provider.api_keys
        |> Enum.sort_by(& &1.inserted_at, DateTime)
        |> Enum.map(&project_admin_key/1),
      models:
        provider.models
        |> Enum.sort_by(& &1.model_id)
        |> Enum.map(&project_admin_model/1),
      inserted_at: provider.inserted_at,
      updated_at: provider.updated_at
    }
  end

  def project_admin_key(key_record) do
    %{
      id: key_record.id,
      provider_id: key_record.provider_id,
      label: key_record.label,
      key_preview: key_record.key_preview,
      enabled: key_record.enabled,
      inserted_at: key_record.inserted_at
    }
  end

  def project_admin_model(model_record) do
    %{
      id: model_record.id,
      provider_id: model_record.provider_id,
      model_id: model_record.model_id,
      upstream_model_id: model_record.upstream_model_id,
      display_name: model_record.display_name,
      enabled: model_record.enabled,
      context_window: model_record.context_window,
      max_output_tokens: model_record.max_output_tokens,
      supports_thinking: model_record.supports_thinking,
      supports_tools: model_record.supports_tools,
      supports_images: model_record.supports_images,
      reasoning_efforts: model_record.reasoning_efforts || [],
      cache_hit_price_mc: model_record.cache_hit_price_mc,
      cache_miss_price_mc: model_record.cache_miss_price_mc,
      output_price_mc: model_record.output_price_mc,
      markup_ratio: model_record.markup_ratio,
      inserted_at: model_record.inserted_at
    }
  end

  def classify_provider_ash_error(error) do
    text = inspect(error)

    if String.contains?(text, "unique_slug") or String.contains?(text, "has already been taken") do
      :slug_taken
    else
      :invalid_name
    end
  end

  def classify_key_ash_error(error) do
    text = inspect(error)

    if String.contains?(text, "unique_provider_fingerprint") or
         String.contains?(text, "has already been taken") do
      :key_duplicate
    else
      :key_empty
    end
  end

  def parse_protocol_atom("anthropic"), do: :anthropic
  def parse_protocol_atom(:anthropic), do: :anthropic
  def parse_protocol_atom(_), do: :openai_compatible

  def map_get(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  def trim_or_empty(val) when is_binary(val), do: String.trim(val)
  def trim_or_empty(_), do: ""

  defp map_get_with_fallback(map, key, fallback) do
    str_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, str_key) -> Map.get(map, str_key)
      true -> fallback
    end
  end

  defp optional_trimmed(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: trimmed
  end

  defp optional_trimmed(_), do: nil

  defp parse_markup(nil), do: 1.5
  defp parse_markup(val) when is_integer(val), do: val * 1.0
  defp parse_markup(val) when is_float(val), do: val
  defp parse_markup(_), do: -1.0

  defp cast_protocol(:openai_compatible), do: {:ok, :openai_compatible}
  defp cast_protocol(:anthropic), do: {:ok, :anthropic}
  defp cast_protocol("openai_compatible"), do: {:ok, :openai_compatible}
  defp cast_protocol("anthropic"), do: {:ok, :anthropic}
  defp cast_protocol(_), do: {:error, :invalid_protocol}
end
