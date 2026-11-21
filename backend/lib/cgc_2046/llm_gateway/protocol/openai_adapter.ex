defmodule Cgc2046.LlmGateway.Protocol.OpenaiAdapter do
  @moduledoc """
  OpenAI Chat Completions 兼容上游适配器：构造标准化上游请求并解析 SSE 响应指标。
  """

  @default_output_tokens 4_096

  @allowed_upstream_keys ~w(
    model
    messages
    tools
    tool_choice
    max_tokens
    temperature
    top_p
    presence_penalty
    frequency_penalty
    stop
    response_format
    seed
    reasoning_effort
    logprobs
    top_logprobs
  )

  @spec build_request(map(), map()) :: %{
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: map(),
          upstream_model: String.t()
        }
  def build_request(params, channel) when is_map(params) and is_map(channel) do
    upstream_model = Map.fetch!(channel, :upstream_model_id)
    max_output_limit = Map.get(channel, :max_output_tokens, 8_192)
    supports_thinking? = Map.get(channel, :supports_thinking, false)

    body =
      params
      |> Map.take(@allowed_upstream_keys)
      |> Map.put("model", upstream_model)
      |> Map.put("stream", true)
      |> Map.put("stream_options", %{"include_usage" => true})
      |> sanitize_params(upstream_model, supports_thinking?, max_output_limit)

    %{
      url: chat_url(channel),
      headers: [
        {"content-type", "application/json"},
        {"accept", "text/event-stream"},
        {"authorization", "Bearer #{Map.fetch!(channel, :api_key)}"}
      ],
      body: body,
      upstream_model: upstream_model
    }
  end

  @spec chat_url(map()) :: String.t()
  def chat_url(channel) when is_map(channel) do
    base_url =
      channel
      |> Map.get(:base_url, "")
      |> to_string()
      |> String.trim()
      |> String.trim_trailing("/")

    path =
      case Map.get(channel, :chat_path) do
        bin when is_binary(bin) ->
          trimmed = String.trim(bin)
          if trimmed == "", do: "/chat/completions", else: ensure_leading_slash(trimmed)

        _ ->
          "/chat/completions"
      end

    base_url <> path
  end

  @doc """
  从原始 OpenAI SSE 字节中提取 content / reasoning_content / tool arguments、
  官方 usage 与 HTTP 200 SSE 错误帧标记。
  """
  @spec parse_sse_frames(String.t()) :: {[iodata()], [iodata()], map() | nil, boolean()}
  def parse_sse_frames(raw_chunk) when is_binary(raw_chunk) do
    raw_chunk
    |> String.split("\n")
    |> Enum.reduce({[], [], nil, false}, fn line,
                                            {content_acc, reasoning_acc, usage_acc, err_acc} ->
      line = String.trim(line)

      if String.starts_with?(line, "data:") do
        payload = line |> String.replace_prefix("data:", "") |> String.trim()

        if payload in ["", "[DONE]"] do
          {content_acc, reasoning_acc, usage_acc, err_acc}
        else
          parse_sse_json_line(payload, content_acc, reasoning_acc, usage_acc, err_acc)
        end
      else
        {content_acc, reasoning_acc, usage_acc, err_acc}
      end
    end)
  end

  defp parse_sse_json_line(payload, content_acc, reasoning_acc, usage_acc, err_acc) do
    case Jason.decode(payload) do
      {:ok, decoded} when is_map(decoded) ->
        has_error? = sse_error_payload?(Map.get(decoded, "error"))
        delta = get_in(decoded, ["choices", Access.at(0), "delta"]) || %{}
        content = Map.get(delta, "content")
        reasoning = Map.get(delta, "reasoning_content")
        tool_args = extract_tool_call_args(delta)

        usage =
          case Map.get(decoded, "usage") do
            usage when is_map(usage) and map_size(usage) > 0 -> usage
            _ -> nil
          end

        next_content =
          content_acc
          |> maybe_append(content)
          |> maybe_append(tool_args)

        next_reasoning = maybe_append(reasoning_acc, reasoning)
        {next_content, next_reasoning, usage || usage_acc, err_acc or has_error?}

      _ ->
        {content_acc, reasoning_acc, usage_acc, err_acc}
    end
  end

  defp sanitize_params(params, upstream_model, supports_thinking?, max_output_limit) do
    downcased = String.downcase(upstream_model)

    strict_reasoner? =
      String.contains?(downcased, "reasoner") or
        String.contains?(downcased, "-r1") or
        String.contains?(downcased, "v4-pro") or
        Regex.match?(~r/^o[134](?:-|$)/, downcased)

    params =
      if strict_reasoner? do
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

    params =
      if not supports_thinking? do
        Map.delete(params, "reasoning_effort")
      else
        params
      end

    default_tokens = min(@default_output_tokens, max_output_limit)

    output_limit =
      case Map.get(params, "max_tokens") do
        max_tokens when is_integer(max_tokens) and max_tokens > 0 ->
          min(max_tokens, max_output_limit)

        _ ->
          default_tokens
      end

    Map.put(params, "max_tokens", output_limit)
  end

  defp sse_error_payload?(err) when is_map(err) and map_size(err) > 0, do: true
  defp sse_error_payload?(err) when is_binary(err) and byte_size(err) > 0, do: true
  defp sse_error_payload?(_), do: false

  defp extract_tool_call_args(%{"tool_calls" => calls}) when is_list(calls) do
    Enum.map_join(calls, "", fn call ->
      if is_map(call), do: get_in(call, ["function", "arguments"]) || "", else: ""
    end)
  end

  defp extract_tool_call_args(_delta), do: nil

  defp maybe_append(list, bin) when is_binary(bin) and byte_size(bin) > 0, do: [list, bin]
  defp maybe_append(list, _), do: list

  defp ensure_leading_slash(path) do
    if String.starts_with?(path, "/"), do: path, else: "/" <> path
  end
end
