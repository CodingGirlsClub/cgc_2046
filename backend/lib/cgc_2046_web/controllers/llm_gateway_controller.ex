defmodule Cgc2046Web.LlmGatewayController do
  @moduledoc """
  OpenAI-compatible `/v1/chat/completions` streaming gateway。

  负责：
  - 并发租约 + 算力预授权 hold 的双重 pre-flight 门禁；
  - `x-session-affinity` 粘性路由与首包前 `:fuse` 熔断 failover；
  - 客户端断开后的上游止损（关闭 Finch 流）；
  - `try ... after` 终态结算：正常用上游 usage，断流用 Tiktoken 估算。
  """

  use Cgc2046Web, :controller

  require Logger

  alias Cgc2046.LlmGateway.AffinityRouter
  alias Cgc2046.LlmGateway.LeaseManager
  alias Cgc2046.LlmGateway.Ledger
  alias Cgc2046.LlmGateway.TokenizerAndPricing
  alias Cgc2046Web.Plugs.RateLimit

  @process_state_key :llm_gateway_stream_state
  @default_receive_timeout_ms 180_000
  @default_pool_timeout_ms 15_000
  @max_request_messages 500
  @default_max_prompt_tokens 250_000

  def chat_completions(conn, params) do
    session_id = extract_session_affinity(conn, params)

    with {:ok, user} <- fetch_user(conn),
         :ok <- check_user_rate_limit(user.id),
         :ok <- validate_request(params),
         [_ | _] = candidates <- AffinityRouter.candidate_channels(user.id, session_id) do
      primary = hd(candidates)
      wallet = Ledger.ensure_wallet!(user.id)

      {logical_model, initial_upstream_model, initial_payload} =
        AffinityRouter.prepare_upstream_payload(params, primary)

      initial_pricing_model = AffinityRouter.pricing_model(primary, logical_model)
      prompt_tokens = TokenizerAndPricing.count_request_prompt_tokens(initial_payload)

      max_prompt_tokens =
        Application.get_env(
          :cgc_2046,
          :llm_gateway_max_prompt_tokens,
          @default_max_prompt_tokens
        )

      if prompt_tokens > max_prompt_tokens do
        prompt_too_large_error(conn)
      else
        hold_mc =
          TokenizerAndPricing.estimate_pre_flight_hold_mc(
            initial_payload,
            initial_pricing_model,
            prompt_tokens
          )

        case LeaseManager.acquire_slot(user.id, wallet.max_concurrent_streams) do
          :ok ->
            case Ledger.acquire_hold(user.id, hold_mc) do
              {:ok, held_wallet} ->
                run_stream(
                  conn,
                  params,
                  user,
                  session_id,
                  candidates,
                  primary,
                  logical_model,
                  initial_upstream_model,
                  initial_pricing_model,
                  prompt_tokens,
                  hold_mc,
                  held_wallet.hold_id
                )

              {:error, reason} ->
                LeaseManager.release_slot(user.id)
                hold_error(conn, reason, user.id)
            end

          {:error, :too_many_concurrent_streams} ->
            concurrency_error(conn)
        end
      end
    else
      [] -> upstream_unavailable(conn)
      {:error, :unauthorized} -> unauthorized(conn)
      {:error, :rate_limited} -> rate_limit_error(conn)
      {:error, :invalid_request} -> invalid_request(conn)
    end
  end

  defp run_stream(
         conn,
         params,
         user,
         session_id,
         candidates,
         primary,
         logical_model,
         initial_upstream_model,
         initial_pricing_model,
         prompt_tokens,
         hold_mc,
         hold_id
       ) do
    start_ms = System.monotonic_time(:millisecond)

    initial_state = %{
      conn: conn,
      channel_id: primary.id,
      channel_provider: Map.get(primary, :provider, :deepseek),
      logical_model: logical_model,
      upstream_model: initial_upstream_model,
      pricing_model: initial_pricing_model,
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

    try do
      stream_with_failover(conn, params, candidates, start_ms)
    rescue
      exception ->
        update_process_state(%{upstream_error?: true})
        Logger.error("llm gateway stream crashed: #{Exception.message(exception)}")
        reraise exception, __STACKTRACE__
    catch
      {:downstream_closed, closed_conn} ->
        closed_conn
    after
      final_state = Process.get(@process_state_key, initial_state)
      duration_ms = System.monotonic_time(:millisecond) - start_ms

      settle_and_release(
        user.id,
        hold_mc,
        prompt_tokens,
        final_state,
        session_id,
        duration_ms,
        hold_id
      )
    end
  end

  defp settle_and_release(
         user_id,
         hold_mc,
         prompt_tokens,
         state,
         session_id,
         duration_ms,
         hold_id
       ) do
    try do
      flushed_state = flush_remaining_sse_buffer()
      state = if map_size(flushed_state) > 0, do: flushed_state, else: state

      settlement =
        TokenizerAndPricing.calculate_settlement(
          Map.get(state, :pricing_model, Map.get(state, :upstream_model)),
          prompt_tokens,
          state
        )

      usage_attrs =
        Map.merge(settlement, %{
          session_id: session_id,
          logical_model: Map.get(state, :logical_model, "cgc-default"),
          upstream_channel: Map.get(state, :channel_id, "unknown"),
          upstream_model: Map.get(state, :upstream_model, "deepseek-chat"),
          ttfb_ms: Map.get(state, :ttfb_ms),
          duration_ms: duration_ms
        })

      case Ledger.settle_usage(user_id, hold_mc, usage_attrs, hold_id: hold_id) do
        {:ok, _wallet} -> :ok
        {:error, reason} -> Logger.error("llm gateway settlement failed: #{inspect(reason)}")
      end
    rescue
      exception ->
        Logger.error("llm gateway settlement crashed: #{Exception.message(exception)}")
    after
      LeaseManager.release_slot(user_id)
    end
  end

  defp stream_with_failover(conn, _params, [], _start_ms), do: conn

  defp stream_with_failover(conn, params, [channel | rest_candidates], start_ms) do
    {logical_model, upstream_model, upstream_payload} =
      AffinityRouter.prepare_upstream_payload(params, channel)

    update_process_state(%{
      channel_id: channel.id,
      channel_provider: Map.get(channel, :provider, :deepseek),
      logical_model: logical_model,
      upstream_model: upstream_model,
      pricing_model: AffinityRouter.pricing_model(channel, logical_model),
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
        url: AffinityRouter.chat_url(channel),
        method: :post,
        headers: [
          {"content-type", "application/json"},
          {"accept", "text/event-stream"},
          {"authorization", "Bearer #{channel.api_key}"}
        ],
        body: Jason.encode!(upstream_payload),
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
      state = Process.get(@process_state_key, %{})

      case result do
        {:ok, %Req.Response{status: status}} ->
          cond do
            Map.get(state, :aborted?, false) ->
              Map.get(state, :conn, conn)

            status in 200..299 ->
              _ = flush_remaining_sse_buffer()

              if Map.get(state, :chunked_started?, false) do
                Map.get(state, :conn, conn)
              else
                start_sse(Map.get(state, :conn, conn))
              end

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

  defp handle_req_data(data, status, start_ms) do
    state = Process.get(@process_state_key, %{})

    if is_integer(status) and status in 200..299 do
      conn =
        if Map.get(state, :chunked_started?, false) do
          Map.get(state, :conn)
        else
          start_sse(Map.get(state, :conn))
        end

      update_process_state(%{chunked_started?: true, conn: conn})

      case handle_stream_data(conn, data, start_ms) do
        {:cont, next_conn} ->
          update_process_state(%{conn: next_conn})
          :cont

        {:halt, _conn} ->
          :halt
      end
    else
      update_process_state(%{error_body: [Map.get(state, :error_body, []) | data]})
      :cont
    end
  end

  defp handle_stream_data(conn, data, start_ms) do
    state = Process.get(@process_state_key, %{})

    ttfb_ms =
      Map.get(state, :ttfb_ms) || System.monotonic_time(:millisecond) - start_ms

    buffer = Map.get(state, :sse_buffer, "") <> data
    {frames, remaining_buffer} = split_sse_frames(buffer)

    {content_fragments, reasoning_fragments, maybe_usage, sse_error?} =
      safe_parse_sse_frames(frames)

    if sse_error? and not Map.get(state, :sse_error?, false) do
      if channel_id = Map.get(state, :channel_id), do: AffinityRouter.report_failure(channel_id)
    end

    new_state = %{
      state
      | first_chunk_sent?: true,
        ttfb_ms: ttfb_ms,
        sse_buffer: remaining_buffer,
        output_iodata: [Map.get(state, :output_iodata, []) | content_fragments],
        reasoning_iodata: [Map.get(state, :reasoning_iodata, []) | reasoning_fragments],
        official_usage: maybe_usage || Map.get(state, :official_usage),
        upstream_error?: Map.get(state, :upstream_error?, false) or sse_error?,
        sse_error?: Map.get(state, :sse_error?, false) or sse_error?
    }

    Process.put(@process_state_key, new_state)

    case Plug.Conn.chunk(conn, data) do
      {:ok, next_conn} ->
        {:cont, next_conn}

      {:error, _closed_reason} ->
        update_process_state(%{aborted?: true})
        {:halt, conn}
    end
  end

  defp start_sse(conn) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
  end

  defp flush_remaining_sse_buffer do
    state = Process.get(@process_state_key, %{})
    buffer = Map.get(state, :sse_buffer, "")

    if is_binary(buffer) and String.trim(buffer) != "" do
      {content_fragments, reasoning_fragments, maybe_usage, sse_error?} =
        safe_parse_sse_frames([buffer])

      if sse_error? and not Map.get(state, :sse_error?, false) do
        if channel_id = Map.get(state, :channel_id), do: AffinityRouter.report_failure(channel_id)
      end

      new_state =
        state
        |> Map.put(:sse_buffer, "")
        |> Map.put(:output_iodata, [Map.get(state, :output_iodata, []) | content_fragments])
        |> Map.put(:reasoning_iodata, [
          Map.get(state, :reasoning_iodata, []) | reasoning_fragments
        ])
        |> Map.put(:official_usage, maybe_usage || Map.get(state, :official_usage))
        |> Map.put(:upstream_error?, Map.get(state, :upstream_error?, false) or sse_error?)
        |> Map.put(:sse_error?, Map.get(state, :sse_error?, false) or sse_error?)

      Process.put(@process_state_key, new_state)
      new_state
    else
      state
    end
  end

  defp split_sse_frames(buffer) do
    normalized = String.replace(buffer, "\r\n", "\n")
    parts = String.split(normalized, "\n\n")
    {Enum.drop(parts, -1), List.last(parts) || ""}
  end

  defp safe_parse_sse_frames([]), do: {[], [], nil, false}

  defp safe_parse_sse_frames(frames) do
    try do
      parse_sse_metrics_with_error(Enum.join(frames, "\n\n"))
    rescue
      _ -> {[], [], nil, false}
    end
  end

  @doc """
  从原始 SSE 字节中提取 delta content / reasoning_content / tool arguments 与
  最终 usage；原始字节仍原样转发给客户端。
  """
  def parse_sse_metrics(raw_chunk) when is_binary(raw_chunk) do
    {content_acc, reasoning_acc, usage_acc, _sse_error?} =
      parse_sse_metrics_with_error(raw_chunk)

    {content_acc, reasoning_acc, usage_acc}
  end

  @doc """
  与 `parse_sse_metrics/1` 相同，但额外返回 `sse_error?`：当上游在 HTTP 200 SSE 流内
  返回 `{"error": ...}` 帧时置为 `true`，供结算免单与熔断上报使用。
  """
  def parse_sse_metrics_with_error(raw_chunk) when is_binary(raw_chunk) do
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
      else
        {content_acc, reasoning_acc, usage_acc, err_acc}
      end
    end)
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

  defp handle_pre_stream_failure(
         conn,
         params,
         failed_channel,
         rest_candidates,
         start_ms,
         reason,
         committed?
       ) do
    state = Process.get(@process_state_key, %{})
    retryable? = retryable_failure?(reason)

    if retryable? do
      AffinityRouter.report_failure(failed_channel.id)
    end

    cond do
      not committed? and rest_candidates != [] and retryable? ->
        # 重放安全边界：尚未向客户端发送任何字节，可以切换渠道。
        stream_with_failover(conn, params, rest_candidates, start_ms)

      committed? ->
        update_process_state(%{upstream_error?: true})
        error_conn = Map.get(state, :conn, conn)
        send_mid_stream_error_frame(error_conn)

      Map.get(state, :first_chunk_sent?, false) ->
        update_process_state(%{upstream_error?: true})
        error_conn = Map.get(state, :conn, conn)
        send_mid_stream_error_frame(error_conn)

      non_retryable_client_error?(reason) ->
        {:http_error, status, raw_body} = reason
        update_process_state(%{upstream_error?: true})
        {http_status, error_code, safe_message} = classify_upstream_client_error(status, raw_body)

        conn
        |> put_status(http_status)
        |> json(%{
          error: %{
            code: error_code,
            type: "invalid_request_error",
            message: safe_message
          }
        })

      true ->
        update_process_state(%{upstream_error?: true})

        conn
        |> put_status(502)
        |> json(%{
          error: %{
            code: "upstream_unavailable",
            type: "upstream_error",
            message: "All upstream LLM channels are temporarily unavailable."
          }
        })
    end
  end

  defp send_mid_stream_error_frame(conn) do
    case Plug.Conn.chunk(conn, mid_stream_error_frame()) do
      {:ok, next_conn} -> next_conn
      {:error, _} -> conn
    end
  end

  defp mid_stream_error_frame do
    "data: " <>
      Jason.encode!(%{
        error: %{
          code: "upstream_stream_interrupted",
          message: "Upstream model stream interrupted mid-generation."
        }
      }) <> "\n\n"
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

  defp classify_upstream_client_error(status, raw_body) do
    {upstream_code, raw_message} = extract_upstream_error(raw_body)

    context_length_exceeded? =
      status == 413 or
        upstream_code == "context_length_exceeded" or
        (is_binary(raw_message) and
           Regex.match?(~r/maximum context length|context_length_exceeded/i, raw_message))

    if context_length_exceeded? do
      safe_message =
        sanitize_upstream_message(
          raw_message,
          "Request exceeds the model's maximum context length."
        )

      {413, "context_length_exceeded", safe_message}
    else
      safe_message =
        sanitize_upstream_message(raw_message, "Upstream rejected the request parameters.")

      {400, "invalid_request", safe_message}
    end
  end

  defp extract_upstream_error(raw_body) when is_binary(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{"error" => %{} = error}} ->
        code =
          case Map.get(error, "code") do
            value when is_binary(value) -> value
            _ -> nil
          end

        message =
          case Map.get(error, "message") do
            value when is_binary(value) -> value
            _ -> nil
          end

        {code, message}

      _ ->
        {nil, nil}
    end
  end

  defp extract_upstream_error(_), do: {nil, nil}

  defp sanitize_upstream_message(message, fallback) when is_binary(message) do
    cleaned =
      message
      |> String.replace(~r/https?:\/\/\S+/i, "[redacted-url]")
      |> String.replace(~r/Bearer\s+[A-Za-z0-9._~+\/=-]+/i, "Bearer [redacted]")
      |> String.replace(~r/\b(?:sk|ark)-[A-Za-z0-9_-]{6,}\b/i, "[redacted-key]")
      |> String.trim()
      |> String.slice(0, 500)

    if cleaned == "", do: fallback, else: cleaned
  end

  defp sanitize_upstream_message(_message, fallback), do: fallback

  defp fetch_user(conn) do
    case conn.assigns[:current_user] do
      %{id: _} = user -> {:ok, user}
      _ -> {:error, :unauthorized}
    end
  end

  defp check_user_rate_limit(user_id) do
    key = RateLimit.build_key("llm_gateway:user", user_id)

    case RateLimit.check(key, limit: :llm_gateway_user_rpm, window_seconds: 60) do
      :ok -> :ok
      :error -> {:error, :rate_limited}
    end
  end

  defp validate_request(params) when is_map(params) do
    messages = Map.get(params, "messages")

    if is_list(messages) and messages != [] and length(messages) <= @max_request_messages and
         Enum.all?(messages, &is_map/1) do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp validate_request(_params), do: {:error, :invalid_request}

  defp extract_session_affinity(conn, params) do
    case get_req_header(conn, "x-session-affinity") do
      [value | _] when is_binary(value) and byte_size(value) > 0 ->
        value

      _ ->
        case Map.get(params, "session_id") do
          value when is_binary(value) and byte_size(value) > 0 -> value
          _ -> nil
        end
    end
  end

  defp update_process_state(updates) do
    current = Process.get(@process_state_key, %{})
    Process.put(@process_state_key, Map.merge(current, updates))
  end

  defp hold_error(conn, :wallet_frozen, user_id) do
    reason =
      try do
        Ledger.fetch_wallet!(user_id).frozen_reason
      rescue
        _ -> nil
      end

    error_body = %{
      code: "wallet_frozen",
      type: "permission_error",
      message: "Your LLM wallet is frozen. Please contact support."
    }

    error_body =
      if is_binary(reason) and String.trim(reason) != "" do
        Map.put(error_body, :reason, reason)
      else
        error_body
      end

    conn
    |> put_status(403)
    |> json(%{error: error_body})
  end

  defp hold_error(conn, _reason, _user_id) do
    conn
    |> put_status(402)
    |> json(%{
      error: %{
        code: "insufficient_quota",
        type: "billing_error",
        message:
          "Insufficient LLM credits. Please renew your subscription or top up a credit pack."
      }
    })
  end

  defp concurrency_error(conn) do
    conn
    |> put_status(429)
    |> json(%{
      error: %{
        code: "concurrency_limit_exceeded",
        type: "rate_limit_error",
        message: "Too many concurrent active streams. Please wait for current tasks to finish."
      }
    })
  end

  defp rate_limit_error(conn) do
    conn
    |> put_status(429)
    |> json(%{
      error: %{
        code: "rate_limit_exceeded",
        type: "rate_limit_error",
        message: "Too many LLM requests. Please slow down."
      }
    })
  end

  defp prompt_too_large_error(conn) do
    conn
    |> put_status(413)
    |> json(%{
      error: %{
        code: "context_length_exceeded",
        type: "invalid_request_error",
        message: "Prompt exceeds maximum allowed token limit."
      }
    })
  end

  defp invalid_request(conn) do
    conn
    |> put_status(400)
    |> json(%{
      error: %{
        code: "invalid_request",
        type: "invalid_request_error",
        message: "messages must be a non-empty array of message objects."
      }
    })
  end

  defp unauthorized(conn) do
    conn
    |> put_status(401)
    |> json(%{
      error: %{
        code: "unauthorized",
        type: "authentication_error",
        message: "A valid first-party session bearer token is required."
      }
    })
  end

  defp upstream_unavailable(conn) do
    conn
    |> put_status(503)
    |> json(%{
      error: %{
        code: "upstream_unavailable",
        type: "upstream_error",
        message: "No LLM gateway channels are configured."
      }
    })
  end
end
