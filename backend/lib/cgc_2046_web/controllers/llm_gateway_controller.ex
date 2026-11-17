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

  @process_state_key :llm_gateway_stream_state

  def chat_completions(conn, params) do
    session_id = extract_session_affinity(conn, params)

    with {:ok, user} <- fetch_user(conn),
         :ok <- validate_request(params),
         [_ | _] = candidates <- AffinityRouter.candidate_channels(user.id, session_id) do
      primary = hd(candidates)
      wallet = Ledger.ensure_wallet!(user.id)

      {logical_model, initial_upstream_model, _} =
        AffinityRouter.prepare_upstream_payload(params, primary)

      prompt_tokens = TokenizerAndPricing.count_request_prompt_tokens(params)
      hold_mc = TokenizerAndPricing.estimate_pre_flight_hold_mc(params, initial_upstream_model)

      case LeaseManager.acquire_slot(user.id, wallet.max_concurrent_streams) do
        :ok ->
          case Ledger.acquire_hold(user.id, hold_mc) do
            {:ok, _held_wallet} ->
              run_stream(
                conn,
                params,
                user,
                session_id,
                candidates,
                primary,
                logical_model,
                initial_upstream_model,
                prompt_tokens,
                hold_mc
              )

            {:error, reason} ->
              LeaseManager.release_slot(user.id)
              hold_error(conn, reason)
          end

        {:error, :too_many_concurrent_streams} ->
          concurrency_error(conn)
      end
    else
      [] -> upstream_unavailable(conn)
      {:error, :unauthorized} -> unauthorized(conn)
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
         prompt_tokens,
         hold_mc
       ) do
    start_ms = System.monotonic_time(:millisecond)

    initial_state = %{
      conn: conn,
      channel_id: primary.id,
      logical_model: logical_model,
      upstream_model: initial_upstream_model,
      output_iodata: [],
      reasoning_iodata: [],
      sse_buffer: "",
      official_usage: nil,
      first_chunk_sent?: false,
      chunked_started?: false,
      ttfb_ms: nil,
      aborted?: false,
      upstream_error?: false
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
      settle_and_release(user.id, hold_mc, prompt_tokens, final_state, session_id, duration_ms)
    end
  end

  defp settle_and_release(user_id, hold_mc, prompt_tokens, state, session_id, duration_ms) do
    try do
      settlement =
        TokenizerAndPricing.calculate_settlement(
          Map.get(state, :upstream_model),
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

      case Ledger.settle_usage(user_id, hold_mc, usage_attrs) do
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
      logical_model: logical_model,
      upstream_model: upstream_model
    })

    url = AffinityRouter.chat_url(channel)

    headers = [
      {"content-type", "application/json"},
      {"accept", "text/event-stream"},
      {"authorization", "Bearer #{channel.api_key}"}
    ]

    body = Jason.encode!(upstream_payload)
    finch_name = Application.get_env(:cgc_2046, :llm_gateway_finch, Cgc2046.LlmGateway.Finch)

    initial_acc = %{
      conn: conn,
      status: nil,
      chunked_started?: false,
      error_body: []
    }

    req = Finch.build(:post, url, headers, body)

    try do
      case Finch.stream(req, finch_name, initial_acc, fn message, acc ->
             handle_finch_message(message, acc, start_ms)
           end) do
        {:ok, %{status: status, conn: final_conn}} when status in 200..299 ->
          final_conn

        {:ok, %{status: status, error_body: error_body, conn: final_conn}} ->
          handle_pre_stream_failure(
            final_conn,
            params,
            channel,
            rest_candidates,
            start_ms,
            {:http_error, status, IO.iodata_to_binary(error_body)},
            false
          )

        {:error, reason} ->
          state = Process.get(@process_state_key, %{})
          committed? = Map.get(state, :chunked_started?, false)
          final_conn = if committed?, do: Map.get(state, :conn, conn), else: conn

          handle_pre_stream_failure(
            final_conn,
            params,
            channel,
            rest_candidates,
            start_ms,
            {:transport_error, reason},
            committed?
          )
      end
    catch
      {:downstream_closed, closed_conn} ->
        closed_conn
    end
  end

  defp handle_finch_message({:status, status}, acc, _start_ms) do
    %{acc | status: status}
  end

  defp handle_finch_message({:headers, _headers}, acc, _start_ms) do
    if acc.status in 200..299 and not acc.chunked_started? do
      chunked_conn =
        acc.conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("x-accel-buffering", "no")
        |> send_chunked(200)

      update_process_state(%{chunked_started?: true, conn: chunked_conn})
      %{acc | conn: chunked_conn, chunked_started?: true}
    else
      acc
    end
  end

  defp handle_finch_message({:data, data}, acc, start_ms) do
    if acc.status in 200..299 do
      handle_sse_data_chunk(acc, data, start_ms)
    else
      %{acc | error_body: [acc.error_body, data]}
    end
  end

  defp handle_finch_message(_message, acc, _start_ms), do: acc

  defp handle_sse_data_chunk(acc, data, start_ms) do
    state = Process.get(@process_state_key, %{})

    ttfb_ms =
      Map.get(state, :ttfb_ms) || System.monotonic_time(:millisecond) - start_ms

    buffer = Map.get(state, :sse_buffer, "") <> data
    {frames, remaining_buffer} = split_sse_frames(buffer)
    {content_fragments, reasoning_fragments, maybe_usage} = safe_parse_sse_frames(frames)

    new_state = %{
      state
      | first_chunk_sent?: true,
        ttfb_ms: ttfb_ms,
        sse_buffer: remaining_buffer,
        output_iodata: [Map.get(state, :output_iodata, []) | content_fragments],
        reasoning_iodata: [Map.get(state, :reasoning_iodata, []) | reasoning_fragments],
        official_usage: maybe_usage || Map.get(state, :official_usage)
    }

    Process.put(@process_state_key, new_state)

    case Plug.Conn.chunk(acc.conn, data) do
      {:ok, next_conn} ->
        update_process_state(%{conn: next_conn})
        %{acc | conn: next_conn}

      {:error, _closed_reason} ->
        update_process_state(%{aborted?: true})
        throw({:downstream_closed, acc.conn})
    end
  end

  defp split_sse_frames(buffer) do
    normalized = String.replace(buffer, "\r\n", "\n")
    parts = String.split(normalized, "\n\n")
    {Enum.drop(parts, -1), List.last(parts) || ""}
  end

  defp safe_parse_sse_frames([]), do: {[], [], nil}

  defp safe_parse_sse_frames(frames) do
    try do
      parse_sse_metrics(Enum.join(frames, "\n\n"))
    rescue
      _ -> {[], [], nil}
    end
  end

  @doc """
  从原始 SSE 字节中提取 delta content / reasoning_content / tool arguments 与
  最终 usage；原始字节仍原样转发给客户端。
  """
  def parse_sse_metrics(raw_chunk) when is_binary(raw_chunk) do
    raw_chunk
    |> String.split("\n")
    |> Enum.reduce({[], [], nil}, fn line, {content_acc, reasoning_acc, usage_acc} ->
      line = String.trim(line)

      if String.starts_with?(line, "data:") do
        payload = line |> String.replace_prefix("data:", "") |> String.trim()

        if payload in ["", "[DONE]"] do
          {content_acc, reasoning_acc, usage_acc}
        else
          case Jason.decode(payload) do
            {:ok, decoded} when is_map(decoded) ->
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
              {next_content, next_reasoning, usage || usage_acc}

            _ ->
              {content_acc, reasoning_acc, usage_acc}
          end
        end
      else
        {content_acc, reasoning_acc, usage_acc}
      end
    end)
  end

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
        _ = Plug.Conn.chunk(error_conn, mid_stream_error_frame())
        error_conn

      Map.get(state, :first_chunk_sent?, false) ->
        update_process_state(%{upstream_error?: true})
        error_conn = Map.get(state, :conn, conn)
        _ = Plug.Conn.chunk(error_conn, mid_stream_error_frame())
        error_conn

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

  defp mid_stream_error_frame do
    "data: " <>
      Jason.encode!(%{
        error: %{
          code: "upstream_stream_interrupted",
          message: "Upstream model stream interrupted mid-generation."
        }
      }) <> "\n\n"
  end

  defp retryable_failure?({:http_error, status, _}) when status in [408, 429, 500, 502, 503, 504],
    do: true

  defp retryable_failure?({:transport_error, _}), do: true
  defp retryable_failure?(_), do: false

  defp fetch_user(conn) do
    case conn.assigns[:current_user] do
      %{id: _} = user -> {:ok, user}
      _ -> {:error, :unauthorized}
    end
  end

  defp validate_request(params) when is_map(params) do
    messages = Map.get(params, "messages")

    if is_list(messages) and messages != [] and Enum.all?(messages, &is_map/1) do
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

  defp hold_error(conn, _reason) do
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
        message: "A valid MCP bearer token is required."
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
