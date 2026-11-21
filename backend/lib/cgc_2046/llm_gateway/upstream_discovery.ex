defmodule Cgc2046.LlmGateway.UpstreamDiscovery do
  @moduledoc """
  上游 Provider URL SSRF 守卫与 `/models` 发现客户端（OpenAI 兼容 + Anthropic 原生）。
  """

  import Bitwise

  alias Cgc2046.LlmGateway.PricingPresets

  @receive_timeout_ms 15_000

  @spec validate_base_url(String.t(), keyword()) :: {:ok, String.t()} | {:error, :invalid_url}
  def validate_base_url(raw_url, opts \\ [])

  def validate_base_url(raw_url, opts) when is_binary(raw_url) do
    trimmed = raw_url |> String.trim() |> String.trim_trailing("/")
    allow_private? = Keyword.get(opts, :allow_private, allow_private_upstreams?())

    with %URI{scheme: scheme, host: host, userinfo: nil} <- URI.parse(trimmed),
         true <- is_binary(host) and host != "",
         true <- valid_scheme?(scheme, allow_private?),
         true <- safe_host?(host, allow_private?) do
      {:ok, trimmed}
    else
      _ -> {:error, :invalid_url}
    end
  end

  def validate_base_url(_, _opts), do: {:error, :invalid_url}

  @spec models_url(atom(), String.t(), String.t() | nil) :: String.t()
  def models_url(protocol, base_url, models_path \\ nil) when is_binary(base_url) do
    root = base_url |> String.trim() |> String.trim_trailing("/")
    custom = models_path && String.trim(models_path)

    cond do
      is_binary(custom) and custom != "" ->
        root <> ensure_leading_slash(custom)

      protocol == :anthropic ->
        if String.ends_with?(root, "/v1") do
          root <> "/models"
        else
          root <> "/v1/models"
        end

      true ->
        root <> "/models"
    end
  end

  @spec fetch_models(map(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_models(provider, api_key, opts \\ [])
      when is_map(provider) and is_binary(api_key) do
    allow_private? = Keyword.get(opts, :allow_private, allow_private_upstreams?())
    protocol = Map.get(provider, :protocol, :openai_compatible)
    base_url = Map.get(provider, :base_url, "")
    models_path = Map.get(provider, :models_path)
    req_plug = Keyword.get(opts, :req_plug) || discovery_req_plug()

    with {:ok, validated_base} <- validate_base_url(base_url, allow_private: allow_private?),
         :ok <- verify_resolved_host(validated_base, allow_private?, req_plug) do
      url = models_url(protocol, validated_base, models_path)
      headers = discovery_headers(protocol, String.trim(api_key))

      req_opts =
        [
          url: url,
          method: :get,
          headers: headers,
          receive_timeout: @receive_timeout_ms,
          retry: false,
          redirect: false
        ]
        |> maybe_put_plug(req_plug)

      case Req.request(req_opts) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          parse_models_response(body)

        {:ok, %Req.Response{status: status}} ->
          {:error, {:upstream_http_status, status}}

        {:error, reason} ->
          {:error, {:upstream_transport, reason}}
      end
    end
  end

  defp maybe_put_plug(opts, nil), do: opts
  defp maybe_put_plug(opts, plug), do: Keyword.put(opts, :plug, plug)

  defp discovery_req_plug do
    Application.get_env(:cgc_2046, :llm_gateway_discovery_req_plug)
  end

  defp discovery_headers(:anthropic, api_key) do
    [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"accept", "application/json"}
    ]
  end

  defp discovery_headers(_protocol, api_key) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"accept", "application/json"}
    ]
  end

  defp parse_models_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_models_response(decoded)
      {:error, _} -> {:error, :invalid_upstream_response}
    end
  end

  defp parse_models_response(%{"data" => rows}) when is_list(rows) do
    {:ok, normalize_model_rows(rows)}
  end

  defp parse_models_response(%{"models" => rows}) when is_list(rows) do
    {:ok, normalize_model_rows(rows)}
  end

  defp parse_models_response(_), do: {:error, :invalid_upstream_response}

  defp normalize_model_rows(rows) do
    {models, _seen} =
      Enum.reduce(rows, {[], MapSet.new()}, fn row, {acc, seen} ->
        case normalize_model_row(row) do
          {:ok, item} ->
            if MapSet.member?(seen, item.model_id) do
              {acc, seen}
            else
              {[item | acc], MapSet.put(seen, item.model_id)}
            end

          :skip ->
            {acc, seen}
        end
      end)

    Enum.reverse(models)
  end

  defp normalize_model_row(row) when is_map(row) do
    raw_id = Map.get(row, "id") || Map.get(row, "name")

    with id when is_binary(id) <- raw_id,
         trimmed = String.trim(id),
         true <- trimmed != "" and String.length(trimmed) <= 128 do
      preset =
        case PricingPresets.lookup(trimmed) do
          {:ok, found} -> found
          :error -> nil
        end

      display_name =
        first_non_empty([
          Map.get(row, "display_name"),
          Map.get(row, "name"),
          preset && preset.display_name,
          trimmed
        ])

      context_window =
        parse_positive_int(
          Map.get(row, "context_window") ||
            Map.get(row, "context_length") ||
            Map.get(row, "max_input_tokens")
        ) || (preset && preset.context_window) || 128_000

      max_output_tokens =
        parse_positive_int(Map.get(row, "max_output_tokens") || Map.get(row, "max_tokens")) ||
          (preset && preset.max_output_tokens) || 8_192

      supports_images =
        case Map.get(row, "input_modalities") do
          list when is_list(list) -> "image" in list
          _ -> (preset && preset.supports_images) || false
        end

      efforts = extract_efforts(row) || (preset && preset.reasoning_efforts) || []

      supports_thinking =
        (preset && preset.supports_thinking) || efforts != [] ||
          String.contains?(String.downcase(trimmed), "reasoner") ||
          String.contains?(String.downcase(trimmed), "-r1")

      {:ok,
       %{
         model_id: trimmed,
         upstream_model_id: trimmed,
         display_name: display_name,
         context_window: context_window,
         max_output_tokens: max_output_tokens,
         supports_thinking: supports_thinking,
         supports_tools: if(preset, do: preset.supports_tools, else: true),
         supports_images: supports_images,
         reasoning_efforts: efforts,
         cache_hit_price_mc: (preset && preset.cache_hit_price_mc) || 0,
         cache_miss_price_mc: (preset && preset.cache_miss_price_mc) || 0,
         output_price_mc: (preset && preset.output_price_mc) || 0,
         markup_ratio: (preset && preset.markup_ratio) || 1.5,
         preset_matched: preset != nil
       }}
    else
      _ -> :skip
    end
  end

  defp normalize_model_row(_), do: :skip

  defp extract_efforts(row) do
    levels =
      get_in(row, ["effort", "supported_levels"]) ||
        Map.get(row, "supported_reasoning_levels") ||
        Map.get(row, "reasoning_levels")

    case levels do
      list when is_list(list) ->
        list
        |> Enum.map(fn
          val when is_binary(val) -> String.trim(val)
          %{"effort" => val} when is_binary(val) -> String.trim(val)
          _ -> ""
        end)
        |> Enum.reject(&(&1 == ""))

      _ ->
        nil
    end
  end

  defp first_non_empty(candidates) do
    Enum.find_value(candidates, fn
      val when is_binary(val) ->
        trimmed = String.trim(val)
        if trimmed != "", do: trimmed, else: nil

      _ ->
        nil
    end)
  end

  defp parse_positive_int(val) when is_integer(val) and val > 0, do: val

  defp parse_positive_int(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {num, ""} when num > 0 -> num
      _ -> nil
    end
  end

  defp parse_positive_int(_), do: nil

  defp valid_scheme?("https", _allow_private?), do: true
  defp valid_scheme?("http", true), do: true
  defp valid_scheme?(_, _), do: false

  defp safe_host?(_host, true), do: true

  defp safe_host?(host, false) do
    downcased = String.downcase(host)

    if downcased in ["localhost", "localhost.localdomain"] or
         String.ends_with?(downcased, ".local") or
         String.ends_with?(downcased, ".internal") do
      false
    else
      case :inet.parse_address(String.to_charlist(downcased)) do
        {:ok, ip} ->
          public_ip?(ip)

        {:error, _} ->
          case resolve_all_ips(downcased) do
            [] -> true
            addrs -> Enum.all?(addrs, &public_ip?/1)
          end
      end
    end
  end

  defp verify_resolved_host(_base_url, true, _req_plug), do: :ok
  defp verify_resolved_host(_base_url, _allow_private?, plug) when not is_nil(plug), do: :ok

  defp verify_resolved_host(base_url, false, nil) do
    %URI{host: host} = URI.parse(base_url)

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        if public_ip?(ip), do: :ok, else: {:error, :invalid_url}

      {:error, _} ->
        case resolve_all_ips(host) do
          [] -> :ok
          addrs -> if Enum.all?(addrs, &public_ip?/1), do: :ok, else: {:error, :invalid_url}
        end
    end
  end

  defp resolve_all_ips(host) do
    charlist = String.to_charlist(host)

    ipv4 =
      case :inet.getaddrs(charlist, :inet) do
        {:ok, list} -> list
        _ -> []
      end

    ipv6 =
      case :inet.getaddrs(charlist, :inet6) do
        {:ok, list} -> list
        _ -> []
      end

    ipv4 ++ ipv6
  end

  defp public_ip?({a, b, _c, _d}) do
    not (a == 0 or
           a == 10 or
           a == 127 or
           (a == 100 and b in 64..127) or
           (a == 169 and b == 254) or
           (a == 172 and b in 16..31) or
           (a == 192 and b == 168) or
           a >= 224)
  end

  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false

  defp public_ip?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}),
    do: public_ip?({ab >>> 8, ab &&& 0xFF, cd >>> 8, cd &&& 0xFF})

  defp public_ip?({a, _, _, _, _, _, _, _}) when (a &&& 0xFE00) == 0xFC00, do: false
  defp public_ip?({a, _, _, _, _, _, _, _}) when (a &&& 0xFFC0) == 0xFE80, do: false
  defp public_ip?({a, _, _, _, _, _, _, _}) when (a &&& 0xFF00) == 0xFF00, do: false
  defp public_ip?({_a, _b, _c, _d, _e, _f, _g, _h}), do: true
  defp public_ip?(_), do: false

  defp ensure_leading_slash(path) do
    if String.starts_with?(path, "/"), do: path, else: "/" <> path
  end

  defp allow_private_upstreams? do
    Application.get_env(:cgc_2046, :llm_gateway_allow_private_upstreams, false)
  end
end
