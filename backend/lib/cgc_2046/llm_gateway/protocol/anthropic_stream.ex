defmodule Cgc2046.LlmGateway.Protocol.AnthropicStream do
  @moduledoc """
  Anthropic Messages SSE 流到标准 OpenAI Chat Completions SSE 流的实时翻译器，
  同时输出计量文本片段、归一化缓存 usage 与错误状态。
  """

  @spec new_stream_state(String.t()) :: map()
  def new_stream_state(client_model) when is_binary(client_model) do
    %{
      message_id: "chatcmpl-cgc",
      model: client_model,
      blocks: %{},
      next_tool_index: 0,
      input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0,
      finish_reason_sent?: false,
      done_sent?: false
    }
  end

  @doc """
  解析一批完整的 Anthropic SSE frame（`\\n\\n` 分隔后的列表），返回
  `{outbound_sse_iodata, content_fragments, reasoning_fragments, maybe_usage, sse_error?, next_state}`。
  """
  @spec translate_sse_frames([String.t()], map()) ::
          {iodata(), [iodata()], [iodata()], map() | nil, boolean(), map()}
  def translate_sse_frames(frames, state) when is_list(frames) and is_map(state) do
    Enum.reduce(frames, {[], [], [], nil, false, state}, fn frame,
                                                            {out_acc, content_acc, reasoning_acc,
                                                             usage_acc, err_acc, cur_state} ->
      {out, c_frags, r_frags, usage, err?, next_state} =
        translate_single_frame(frame, cur_state)

      {
        [out_acc, out],
        [content_acc | c_frags],
        [reasoning_acc | r_frags],
        usage || usage_acc,
        err_acc or err?,
        next_state
      }
    end)
  end

  defp translate_single_frame(frame, state) do
    case extract_sse_data(frame) do
      nil ->
        {[], [], [], nil, false, state}

      payload ->
        case Jason.decode(payload) do
          {:ok, %{"type" => type} = event} ->
            handle_anthropic_event(type, event, state)

          _ ->
            {[], [], [], nil, false, state}
        end
    end
  end

  defp extract_sse_data(frame) do
    data_lines =
      frame
      |> String.split("\n")
      |> Enum.reduce([], fn line, acc ->
        trimmed = String.trim(line)

        if String.starts_with?(trimmed, "data:") do
          [trimmed |> String.replace_prefix("data:", "") |> String.trim() | acc]
        else
          acc
        end
      end)
      |> Enum.reverse()

    case data_lines do
      [] -> nil
      lines -> Enum.join(lines, "\n") |> then(&if(&1 == "", do: nil, else: &1))
    end
  end

  defp handle_anthropic_event("message_start", %{"message" => msg}, state) when is_map(msg) do
    msg_id = Map.get(msg, "id") || state.message_id

    next_state =
      state
      |> Map.put(:message_id, msg_id)
      |> merge_anthropic_usage(Map.get(msg, "usage"))

    {[], [], [], nil, false, next_state}
  end

  defp handle_anthropic_event(
         "content_block_start",
         %{"index" => idx, "content_block" => block},
         state
       )
       when is_integer(idx) and is_map(block) do
    case Map.get(block, "type") do
      "text" ->
        next_state = put_in(state, [:blocks, idx], :text)
        initial = Map.get(block, "text", "")

        if is_binary(initial) and initial != "" do
          chunk = sse_delta_chunk(next_state, %{"content" => initial})
          {chunk, [initial], [], nil, false, next_state}
        else
          {[], [], [], nil, false, next_state}
        end

      "thinking" ->
        next_state = put_in(state, [:blocks, idx], :thinking)
        initial = Map.get(block, "thinking", "")

        if is_binary(initial) and initial != "" do
          chunk = sse_delta_chunk(next_state, %{"reasoning_content" => initial})
          {chunk, [], [initial], nil, false, next_state}
        else
          {[], [], [], nil, false, next_state}
        end

      "tool_use" ->
        tc_idx = state.next_tool_index

        next_state =
          state
          |> Map.put(:next_tool_index, tc_idx + 1)
          |> put_in([:blocks, idx], {:tool_use, tc_idx})

        initial_args =
          case Map.get(block, "input") do
            input when is_map(input) and map_size(input) > 0 -> Jason.encode!(input)
            _ -> ""
          end

        tool_call_delta = %{
          "index" => tc_idx,
          "id" => Map.get(block, "id", "call_#{tc_idx}"),
          "type" => "function",
          "function" => %{
            "name" => Map.get(block, "name", ""),
            "arguments" => initial_args
          }
        }

        chunk = sse_delta_chunk(next_state, %{"tool_calls" => [tool_call_delta]})
        c_frags = if initial_args == "", do: [], else: [initial_args]
        {chunk, c_frags, [], nil, false, next_state}

      _ ->
        {[], [], [], nil, false, state}
    end
  end

  defp handle_anthropic_event(
         "content_block_delta",
         %{"index" => idx, "delta" => delta},
         state
       )
       when is_integer(idx) and is_map(delta) do
    case {Map.get(delta, "type"), get_in(state, [:blocks, idx])} do
      {"text_delta", :text} ->
        text = Map.get(delta, "text", "")

        if is_binary(text) and text != "" do
          {sse_delta_chunk(state, %{"content" => text}), [text], [], nil, false, state}
        else
          {[], [], [], nil, false, state}
        end

      {"thinking_delta", :thinking} ->
        thinking = Map.get(delta, "thinking", "")

        if is_binary(thinking) and thinking != "" do
          {sse_delta_chunk(state, %{"reasoning_content" => thinking}), [], [thinking], nil, false,
           state}
        else
          {[], [], [], nil, false, state}
        end

      {"input_json_delta", {:tool_use, tc_idx}} ->
        partial = Map.get(delta, "partial_json", "")

        if is_binary(partial) and partial != "" do
          tool_delta = %{
            "index" => tc_idx,
            "function" => %{"arguments" => partial}
          }

          {sse_delta_chunk(state, %{"tool_calls" => [tool_delta]}), [partial], [], nil, false,
           state}
        else
          {[], [], [], nil, false, state}
        end

      _ ->
        {[], [], [], nil, false, state}
    end
  end

  defp handle_anthropic_event("content_block_stop", %{"index" => idx}, state)
       when is_integer(idx) do
    next_state = update_in(state, [:blocks], &Map.delete(&1, idx))
    {[], [], [], nil, false, next_state}
  end

  defp handle_anthropic_event("message_delta", event, state) do
    next_state = merge_anthropic_usage(state, Map.get(event, "usage"))
    stop_reason = get_in(event, ["delta", "stop_reason"])

    case map_stop_reason(stop_reason) do
      nil ->
        {[], [], [], nil, false, next_state}

      mapped ->
        chunk =
          sse_json_frame(%{
            "id" => next_state.message_id,
            "object" => "chat.completion.chunk",
            "model" => next_state.model,
            "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => mapped}]
          })

        {chunk, [], [], nil, false, Map.put(next_state, :finish_reason_sent?, true)}
    end
  end

  defp handle_anthropic_event("message_stop", _event, state) do
    finish_chunk =
      if state.finish_reason_sent? do
        []
      else
        sse_json_frame(%{
          "id" => state.message_id,
          "object" => "chat.completion.chunk",
          "model" => state.model,
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
        })
      end

    usage = normalized_openai_usage(state)

    usage_chunk =
      sse_json_frame(%{
        "id" => state.message_id,
        "object" => "chat.completion.chunk",
        "model" => state.model,
        "choices" => [],
        "usage" => usage
      })

    done_frame = "data: [DONE]\n\n"
    next_state = Map.merge(state, %{finish_reason_sent?: true, done_sent?: true})
    {[finish_chunk, usage_chunk, done_frame], [], [], usage, false, next_state}
  end

  defp handle_anthropic_event("error", event, state) do
    err = Map.get(event, "error") || %{}

    error_frame =
      sse_json_frame(%{
        "error" => %{
          "code" => Map.get(err, "type", "upstream_error"),
          "message" => Map.get(err, "message", "Anthropic upstream error")
        }
      })

    {error_frame, [], [], nil, true, state}
  end

  defp handle_anthropic_event(_other, _event, state) do
    {[], [], [], nil, false, state}
  end

  defp merge_anthropic_usage(state, usage) when is_map(usage) do
    state
    |> maybe_set_usage(:input_tokens, Map.get(usage, "input_tokens"))
    |> maybe_set_usage(:output_tokens, Map.get(usage, "output_tokens"))
    |> maybe_set_usage(:cache_read_tokens, Map.get(usage, "cache_read_input_tokens"))
    |> maybe_set_usage(:cache_creation_tokens, Map.get(usage, "cache_creation_input_tokens"))
  end

  defp merge_anthropic_usage(state, _), do: state

  defp maybe_set_usage(state, key, val) when is_integer(val) and val >= 0 do
    Map.put(state, key, val)
  end

  defp maybe_set_usage(state, _key, _val), do: state

  defp normalized_openai_usage(state) do
    prompt_total = state.input_tokens + state.cache_read_tokens + state.cache_creation_tokens
    miss_tokens = state.input_tokens + state.cache_creation_tokens

    %{
      "prompt_tokens" => prompt_total,
      "prompt_cache_hit_tokens" => state.cache_read_tokens,
      "prompt_cache_miss_tokens" => miss_tokens,
      "prompt_tokens_details" => %{"cached_tokens" => state.cache_read_tokens},
      "completion_tokens" => state.output_tokens,
      "total_tokens" => prompt_total + state.output_tokens
    }
  end

  defp map_stop_reason("end_turn"), do: "stop"
  defp map_stop_reason("stop_sequence"), do: "stop"
  defp map_stop_reason("max_tokens"), do: "length"
  defp map_stop_reason("model_context_window_exceeded"), do: "length"
  defp map_stop_reason("tool_use"), do: "tool_calls"
  defp map_stop_reason("refusal"), do: "content_filter"
  defp map_stop_reason(_), do: nil

  defp sse_delta_chunk(state, delta) do
    sse_json_frame(%{
      "id" => state.message_id,
      "object" => "chat.completion.chunk",
      "model" => state.model,
      "choices" => [%{"index" => 0, "delta" => delta}]
    })
  end

  defp sse_json_frame(payload) do
    "data: " <> Jason.encode!(payload) <> "\n\n"
  end
end
