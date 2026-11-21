defmodule Cgc2046Web.LlmGatewayStream do
  @moduledoc """
  LLM Gateway SSE 流式转发、首包前 failover 与协议帧缓冲状态机。
  """

  alias Cgc2046.LlmGateway.AffinityRouter
  alias Cgc2046.LlmGateway.Protocol.AnthropicAdapter
  alias Cgc2046.LlmGateway.Protocol.OpenaiAdapter
  alias Cgc2046Web.LlmGatewayErrors, as: Errors

  @process_state_key :llm_gateway_stream_state
  @default_receive_timeout_ms 180_000
  @default_pool_timeout_ms 15_000

  def init_state(conn, primary, requested_model) do
    initial_state = %{
      conn: conn,
      channel_id: primary.id,
      channel_label: primary.channel_label,
      protocol: primary.protocol,
      off_peak_discount_enabled: primary.off_peak_discount_enabled,
      logical_model: requested_model,
      upstream_model: primary.upstream_model_id,
      pricing: primary.pricing,
      anthropic_stream_state: init_protocol_stream_state(primary.protocol, requested_model),
      output_iodata: [],
      reasoning_iodata: [],
      sse_buffer: "",
      error_body: [],
      official_usage: nil,
      first_chunk_sent?: false,
      chunked_started?: false,
      ttfb_ms: nil,
      aborted?: false,
      upstream_error?: false,
      sse_error?: false
    }

    Process.put(@process_state_key, initial_state)
    initial_state
  end

  def get_state(fallback \\ %{}) do
    Process.get(@process_state_key, fallback)
  end

  def update_state(updates) do
    current = Process.get(@process_state_key, %{})
    Process.put(@process_state_key, Map.merge(current, updates))
  end

  def delete_state do
    Process.delete(@process_state_key)
  end

  def stream_with_failover(conn, _params, [], _start_ms), do: conn

  def stream_with_failover(conn, params, [channel | rest_candidates], start_ms) do
    %{url: url, headers: headers, body: body, upstream_model: upstream_model} =
      AffinityRouter.build_upstream_request(params, channel)

    update_state(%{
      channel_id: channel.id,
      channel_label: channel.channel_label,
      protocol: channel.protocol,
      off_peak_discount_enabled: channel.off_peak_discount_enabled,
      upstream_model: upstream_model,
      pricing: channel.pricing,
      anthropic_stream_state: init_protocol_stream_state(channel.protocol, channel.model_id),
      sse_buffer: "",
      error_body: []
    })

    finch_name = Application.get_env(:cgc_2046, :llm_gateway_finch, Cgc2046.LlmGateway.Finch)

    receive_timeout =
      Application.get_env(
        :cgc_2046,
        :llm_gateway_receive_timeout_ms,
        @default_receive_timeout_ms
      )

    pool_timeout =
      Application.get_env(
        :cgc_2046,
        :llm_gateway_pool_timeout_ms,
        @default_pool_timeout_ms
      )

    req =
      Req.new(
        url: url,
        method: :post,
        headers: headers,
        body: Jason.encode!(body),
        finch: finch_name,
        receive_timeout: receive_timeout,
        pool_timeout: pool_timeout,
        retry: false,
        redirect: false,
        decode_body: false,
        into: fn {:data, data}, {req, resp} ->
          case handle_req_data(data, resp.status, start_ms) do
            :cont -> {:cont, {req, resp}}
            :halt -> {:halt, {req, resp}}
          end
        end
      )

    try do
      result = Req.request(req)
      state = get_state()

      case result do
        {:ok, %Req.Response{status: status}} ->
          cond do
            Map.get(state, :aborted?, false) ->
              Map.get(state, :conn, conn)

            status in 200..299 ->
              finalize_success_stream(Map.get(state, :conn, conn))

            true ->
              handle_pre_stream_failure(
                Map.get(state, :conn, conn),
                params,
                channel,
                rest_candidates,
                start_ms,
                {:http_error, status, IO.iodata_to_binary(Map.get(state, :error_body, []))},
                false
              )
          end

        {:error, exception} ->
          committed? = Map.get(state, :chunked_started?, false)

          handle_pre_stream_failure(
            Map.get(state, :conn, conn),
            params,
            channel,
            rest_candidates,
            start_ms,
            {:transport_error, exception},
            committed?
          )
      end
    catch
      {:downstream_closed, closed_conn} -> closed_conn
    end
  end

  def flush_remaining_sse_buffer do
    state = get_state()
    buffer = Map.get(state, :sse_buffer, "")

    if is_binary(buffer) and String.trim(buffer) != "" do
      {out_chunk, c_frags, r_frags, maybe_usage, sse_error?, next_proto_state} =
        case Map.get(state, :protocol) do
          :anthropic ->
            AnthropicAdapter.translate_sse_frames([buffer], state.anthropic_stream_state)

          _ ->
            {cf, rf, u, err?} =
              try do
                OpenaiAdapter.parse_sse_frames(buffer)
              rescue
                _ -> {[], [], nil, false}
              end

            {[], cf, rf, u, err?, state.anthropic_stream_state}
        end

      if sse_error? and not Map.get(state, :sse_error?, false) do
        if channel_id = Map.get(state, :channel_id), do: AffinityRouter.report_failure(channel_id)
      end

      new_state =
        state
        |> Map.put(:sse_buffer, "")
        |> Map.put(:anthropic_stream_state, next_proto_state)
        |> Map.put(:output_iodata, [Map.get(state, :output_iodata, []) | c_frags])
        |> Map.put(:reasoning_iodata, [Map.get(state, :reasoning_iodata, []) | r_frags])
        |> Map.put(:official_usage, maybe_usage || Map.get(state, :official_usage))
        |> Map.put(:upstream_error?, Map.get(state, :upstream_error?, false) or sse_error?)
        |> Map.put(:sse_error?, Map.get(state, :sse_error?, false) or sse_error?)

      Process.put(@process_state_key, new_state)
      {new_state, out_chunk}
    else
      {state, []}
    end
  end

  defp finalize_success_stream(conn) do
    {flushed_state, trailing_out} = flush_remaining_sse_buffer()
    chunked? = Map.get(flushed_state, :chunked_started?, false)
    conn = if chunked?, do: Map.get(flushed_state, :conn, conn), else: start_sse(conn)

    if IO.iodata_length(trailing_out) > 0 do
      case Plug.Conn.chunk(conn, trailing_out) do
        {:ok, next_conn} ->
          update_state(%{conn: next_conn, chunked_started?: true})
          next_conn

        {:error, _} ->
          update_state(%{aborted?: true})
          conn
      end
    else
      conn
    end
  end

  defp handle_req_data(data, status, start_ms) do
    state = get_state()

    if is_integer(status) and status in 200..299 do
      conn =
        if Map.get(state, :chunked_started?, false) do
          Map.get(state, :conn)
        else
          start_sse(Map.get(state, :conn))
        end

      update_state(%{chunked_started?: true, conn: conn})

      case handle_stream_data(conn, data, start_ms) do
        {:cont, next_conn} ->
          update_state(%{conn: next_conn})
          :cont

        {:halt, _conn} ->
          :halt
      end
    else
      update_state(%{error_body: [Map.get(state, :error_body, []) | data]})
      :cont
    end
  end

  defp handle_stream_data(conn, data, start_ms) do
    state = get_state()
    ttfb_ms = Map.get(state, :ttfb_ms) || System.monotonic_time(:millisecond) - start_ms
    buffer = Map.get(state, :sse_buffer, "") <> data
    {frames, remaining_buffer} = split_sse_frames(buffer)

    {outbound_chunk, content_frags, reasoning_frags, maybe_usage, sse_error?, next_proto_state} =
      process_frames(frames, data, state)

    if sse_error? and not Map.get(state, :sse_error?, false) do
      if channel_id = Map.get(state, :channel_id), do: AffinityRouter.report_failure(channel_id)
    end

    new_state = %{
      state
      | first_chunk_sent?: true,
        ttfb_ms: ttfb_ms,
        sse_buffer: remaining_buffer,
        anthropic_stream_state: next_proto_state,
        output_iodata: [Map.get(state, :output_iodata, []) | content_frags],
        reasoning_iodata: [Map.get(state, :reasoning_iodata, []) | reasoning_frags],
        official_usage: maybe_usage || Map.get(state, :official_usage),
        upstream_error?: Map.get(state, :upstream_error?, false) or sse_error?,
        sse_error?: Map.get(state, :sse_error?, false) or sse_error?
    }

    Process.put(@process_state_key, new_state)

    if IO.iodata_length(outbound_chunk) == 0 do
      {:cont, conn}
    else
      case Plug.Conn.chunk(conn, outbound_chunk) do
        {:ok, next_conn} ->
          {:cont, next_conn}

        {:error, _closed_reason} ->
          update_state(%{aborted?: true})
          {:halt, conn}
      end
    end
  end

  defp process_frames([], raw_data, %{protocol: :openai_compatible} = state) do
    {raw_data, [], [], nil, false, state.anthropic_stream_state}
  end

  defp process_frames([], _raw_data, %{protocol: :anthropic} = state) do
    {[], [], [], nil, false, state.anthropic_stream_state}
  end

  defp process_frames(frames, _raw_data, %{protocol: :anthropic} = state) do
    AnthropicAdapter.translate_sse_frames(frames, state.anthropic_stream_state)
  end

  defp process_frames(frames, raw_data, state) do
    {c_frags, r_frags, usage, sse_error?} =
      try do
        OpenaiAdapter.parse_sse_frames(Enum.join(frames, "\n\n"))
      rescue
        _ -> {[], [], nil, false}
      end

    {raw_data, c_frags, r_frags, usage, sse_error?, state.anthropic_stream_state}
  end

  defp init_protocol_stream_state(:anthropic, model_id),
    do: AnthropicAdapter.new_stream_state(model_id)

  defp init_protocol_stream_state(_, _model_id), do: nil

  defp start_sse(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.put_resp_header("cache-control", "no-cache")
    |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
    |> Plug.Conn.send_chunked(200)
  end

  defp split_sse_frames(buffer) do
    normalized = String.replace(buffer, "\r\n", "\n")
    parts = String.split(normalized, "\n\n")
    {Enum.drop(parts, -1), List.last(parts) || ""}
  end

  defp handle_pre_stream_failure(
         conn,
         params,
         failed_channel,
         rest_candidates,
         start_ms,
         reason,
         committed?
       ) do
    state = get_state()
    retryable? = retryable_failure?(reason)

    if retryable? do
      AffinityRouter.report_failure(failed_channel.id)
    end

    cond do
      not committed? and rest_candidates != [] and retryable? ->
        stream_with_failover(conn, params, rest_candidates, start_ms)

      committed? ->
        update_state(%{upstream_error?: true})
        Errors.send_mid_stream_error_frame(Map.get(state, :conn, conn))

      Map.get(state, :first_chunk_sent?, false) ->
        update_state(%{upstream_error?: true})
        Errors.send_mid_stream_error_frame(Map.get(state, :conn, conn))

      non_retryable_client_error?(reason) ->
        {:http_error, status, raw_body} = reason
        update_state(%{upstream_error?: true})

        {http_status, error_code, safe_message} =
          Errors.classify_upstream_client_error(status, raw_body)

        Errors.send_error(conn, http_status, error_code, "invalid_request_error", safe_message)

      true ->
        update_state(%{upstream_error?: true})

        Errors.upstream_unavailable(
          conn,
          502,
          "All upstream LLM channels are temporarily unavailable."
        )
    end
  end

  defp retryable_failure?({:http_error, status, _})
       when status in [401, 403, 408, 429, 500, 502, 503, 504],
       do: true

  defp retryable_failure?({:transport_error, _}), do: true
  defp retryable_failure?(_), do: false

  defp non_retryable_client_error?({:http_error, status, _})
       when is_integer(status) and status in 400..499 and status not in [401, 403, 408, 429],
       do: true

  defp non_retryable_client_error?(_), do: false
end
