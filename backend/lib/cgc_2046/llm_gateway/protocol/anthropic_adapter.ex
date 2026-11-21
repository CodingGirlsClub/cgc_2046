defmodule Cgc2046.LlmGateway.Protocol.AnthropicAdapter do
  @moduledoc """
  Anthropic Messages API 协议适配器：
  负责将客户端 OpenAI Chat Completions 请求体转换并发送至 Anthropic `/v1/messages`，
  SSE 流式响应翻译委托给 `AnthropicStream`。
  """

  alias Cgc2046.LlmGateway.Protocol.AnthropicStream

  @anthropic_version "2023-06-01"
  @default_output_tokens 4_096

  defdelegate new_stream_state(client_model), to: AnthropicStream
  defdelegate translate_sse_frames(frames, state), to: AnthropicStream

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

    {system_parts, messages} = convert_messages(Map.get(params, "messages", []))

    max_tokens =
      case Map.get(params, "max_tokens") do
        val when is_integer(val) and val > 0 -> min(val, max_output_limit)
        _ -> min(@default_output_tokens, max_output_limit)
      end

    body =
      %{
        "model" => upstream_model,
        "messages" => messages,
        "max_tokens" => max_tokens,
        "stream" => true
      }
      |> maybe_put_system(system_parts)
      |> maybe_put_tools(Map.get(params, "tools"))
      |> maybe_put_tool_choice(Map.get(params, "tool_choice"))
      |> maybe_put_stop_sequences(Map.get(params, "stop"))
      |> apply_thinking_and_sampling(params, supports_thinking?, max_tokens)

    %{
      url: messages_url(channel),
      headers: [
        {"content-type", "application/json"},
        {"accept", "text/event-stream"},
        {"x-api-key", Map.fetch!(channel, :api_key)},
        {"anthropic-version", @anthropic_version}
      ],
      body: body,
      upstream_model: upstream_model
    }
  end

  @spec messages_url(map()) :: String.t()
  def messages_url(channel) when is_map(channel) do
    base_url =
      channel
      |> Map.get(:base_url, "")
      |> to_string()
      |> String.trim()
      |> String.trim_trailing("/")

    case Map.get(channel, :chat_path) do
      bin when is_binary(bin) ->
        trimmed = String.trim(bin)

        cond do
          trimmed != "" -> base_url <> ensure_leading_slash(trimmed)
          String.ends_with?(base_url, "/v1") -> base_url <> "/messages"
          true -> base_url <> "/v1/messages"
        end

      _ ->
        if String.ends_with?(base_url, "/v1") do
          base_url <> "/messages"
        else
          base_url <> "/v1/messages"
        end
    end
  end

  defp convert_messages(messages) when is_list(messages) do
    {sys_acc, msg_acc} =
      Enum.reduce(messages, {[], []}, fn msg, {sys, msgs} ->
        case Map.get(msg, "role") do
          role when role in ["system", "developer"] ->
            text = extract_plain_text(Map.get(msg, "content"))
            if text == "", do: {sys, msgs}, else: {[text | sys], msgs}

          "user" ->
            blocks = convert_user_content(Map.get(msg, "content"))
            {sys, append_anthropic_message(msgs, "user", blocks)}

          "assistant" ->
            blocks = convert_assistant_message(msg)
            {sys, append_anthropic_message(msgs, "assistant", blocks)}

          "tool" ->
            block = convert_tool_result_message(msg)
            {sys, append_anthropic_message(msgs, "user", [block])}

          _ ->
            {sys, msgs}
        end
      end)

    {Enum.reverse(sys_acc), Enum.reverse(msg_acc)}
  end

  defp convert_messages(_), do: {[], []}

  defp append_anthropic_message(acc, _role, []), do: acc

  defp append_anthropic_message(
         [%{"role" => role, "content" => prev_blocks} | rest],
         role,
         blocks
       ) do
    [%{"role" => role, "content" => prev_blocks ++ blocks} | rest]
  end

  defp append_anthropic_message(acc, role, blocks) do
    [%{"role" => role, "content" => blocks} | acc]
  end

  defp convert_user_content(content) when is_binary(content) do
    if content == "", do: [], else: [%{"type" => "text", "text" => content}]
  end

  defp convert_user_content(parts) when is_list(parts) do
    Enum.flat_map(parts, fn
      %{"type" => "text", "text" => text} when is_binary(text) and text != "" ->
        [%{"type" => "text", "text" => text}]

      %{"type" => "image_url", "image_url" => %{"url" => url}} when is_binary(url) ->
        convert_image_url(url)

      _ ->
        []
    end)
  end

  defp convert_user_content(_), do: []

  defp convert_image_url(url) do
    case Regex.run(~r/^data:([^;]+);base64,(.+)$/s, url) do
      [_, media_type, data] ->
        [
          %{
            "type" => "image",
            "source" => %{"type" => "base64", "media_type" => media_type, "data" => data}
          }
        ]

      nil ->
        if String.starts_with?(url, "https://") or String.starts_with?(url, "http://") do
          [%{"type" => "image", "source" => %{"type" => "url", "url" => url}}]
        else
          []
        end
    end
  end

  defp convert_assistant_message(msg) do
    text_blocks = convert_user_content(Map.get(msg, "content"))

    tool_blocks =
      case Map.get(msg, "tool_calls") do
        calls when is_list(calls) -> Enum.flat_map(calls, &convert_tool_call/1)
        _ -> []
      end

    text_blocks ++ tool_blocks
  end

  defp convert_tool_call(%{"id" => id, "function" => %{"name" => name} = func})
       when is_binary(id) and is_binary(name) do
    input =
      case Map.get(func, "arguments") do
        raw when is_binary(raw) and raw != "" ->
          case Jason.decode(raw) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _ -> %{}
          end

        map when is_map(map) ->
          map

        _ ->
          %{}
      end

    [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}]
  end

  defp convert_tool_call(_), do: []

  defp convert_tool_result_message(msg) do
    content = extract_plain_text(Map.get(msg, "content"))

    base = %{
      "type" => "tool_result",
      "tool_use_id" => Map.get(msg, "tool_call_id", ""),
      "content" => content
    }

    if Map.get(msg, "is_error") == true, do: Map.put(base, "is_error", true), else: base
  end

  defp extract_plain_text(content) when is_binary(content), do: content

  defp extract_plain_text(parts) when is_list(parts) do
    parts
    |> Enum.map_join("", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp extract_plain_text(_), do: ""

  defp maybe_put_system(body, []), do: body
  defp maybe_put_system(body, parts), do: Map.put(body, "system", Enum.join(parts, "\n\n"))

  defp maybe_put_tools(body, tools) when is_list(tools) and tools != [] do
    converted =
      Enum.flat_map(tools, fn
        %{"type" => "function", "function" => %{"name" => name} = func} ->
          [
            %{
              "name" => name,
              "description" => Map.get(func, "description") || "",
              "input_schema" =>
                Map.get(func, "parameters") || %{"type" => "object", "properties" => %{}}
            }
          ]

        %{"name" => name} = tool ->
          [
            %{
              "name" => name,
              "description" => Map.get(tool, "description") || "",
              "input_schema" =>
                Map.get(tool, "input_schema") ||
                  Map.get(tool, "parameters") ||
                  %{"type" => "object", "properties" => %{}}
            }
          ]

        _ ->
          []
      end)

    if converted == [], do: body, else: Map.put(body, "tools", converted)
  end

  defp maybe_put_tools(body, _), do: body

  defp maybe_put_tool_choice(body, "auto"), do: Map.put(body, "tool_choice", %{"type" => "auto"})

  defp maybe_put_tool_choice(body, "required"),
    do: Map.put(body, "tool_choice", %{"type" => "any"})

  defp maybe_put_tool_choice(body, "none"), do: Map.put(body, "tool_choice", %{"type" => "none"})

  defp maybe_put_tool_choice(body, %{"type" => "function", "function" => %{"name" => name}})
       when is_binary(name) and name != "" do
    Map.put(body, "tool_choice", %{"type" => "tool", "name" => name})
  end

  defp maybe_put_tool_choice(body, _), do: body

  defp maybe_put_stop_sequences(body, stop) when is_binary(stop) and stop != "" do
    Map.put(body, "stop_sequences", [stop])
  end

  defp maybe_put_stop_sequences(body, stops) when is_list(stops) do
    filtered = Enum.filter(stops, &(is_binary(&1) and &1 != ""))
    if filtered == [], do: body, else: Map.put(body, "stop_sequences", filtered)
  end

  defp maybe_put_stop_sequences(body, _), do: body

  defp apply_thinking_and_sampling(body, params, supports_thinking?, max_tokens) do
    effort = Map.get(params, "reasoning_effort")

    budget =
      if supports_thinking? and is_binary(effort) and max_tokens > 1_024 do
        target =
          case effort do
            "low" -> 2_048
            "medium" -> 4_096
            "high" -> 8_192
            "xhigh" -> 16_384
            "max" -> 16_384
            _ -> nil
          end

        if target, do: min(target, max_tokens - 1), else: nil
      else
        nil
      end

    if is_integer(budget) and budget >= 1_024 do
      Map.put(body, "thinking", %{"type" => "enabled", "budget_tokens" => budget})
    else
      body
      |> maybe_put_number("temperature", Map.get(params, "temperature"))
      |> maybe_put_number("top_p", Map.get(params, "top_p"))
    end
  end

  defp maybe_put_number(body, key, val) when is_number(val), do: Map.put(body, key, val)
  defp maybe_put_number(body, _key, _), do: body

  defp ensure_leading_slash(path) do
    if String.starts_with?(path, "/"), do: path, else: "/" <> path
  end
end
