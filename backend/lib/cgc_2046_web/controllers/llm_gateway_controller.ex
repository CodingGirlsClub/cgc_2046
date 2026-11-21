defmodule Cgc2046Web.LlmGatewayController do
  @moduledoc """
  OpenAI-compatible `/v1/models` 与 `/v1/chat/completions` 流式代理网关。

  负责：
  - 并发租约 + 算力预授权 hold 的双重 pre-flight 门禁；
  - 基于 DB `ProviderCatalog` 的模型路由、`x-session-affinity` 会话亲和与首包前 `:fuse` 熔断 failover；
  - OpenAI 兼容透传与 Anthropic Messages API 双向协议转换；
  - 客户端断开后的上游止损与 `try ... after` 终态结算。
  """

  use Cgc2046Web, :controller

  require Logger

  alias Cgc2046.LlmGateway.AffinityRouter
  alias Cgc2046.LlmGateway.LeaseManager
  alias Cgc2046.LlmGateway.Ledger
  alias Cgc2046.LlmGateway.Protocol.OpenaiAdapter
  alias Cgc2046.LlmGateway.ProviderCatalog
  alias Cgc2046.LlmGateway.TokenizerAndPricing
  alias Cgc2046Web.LlmGatewayErrors, as: Errors
  alias Cgc2046Web.LlmGatewayStream
  alias Cgc2046Web.Plugs.RateLimit

  @max_request_messages 500
  @max_model_name_bytes 256
  @default_max_prompt_tokens 250_000

  def models(conn, _params) do
    case fetch_user(conn) do
      {:ok, _user} ->
        items =
          ProviderCatalog.list_available_models()
          |> Enum.map(fn model ->
            %{
              id: model.model_id,
              object: "model",
              owned_by: "cgc-cloud",
              display_name: model.display_name,
              context_window: model.context_window,
              max_output_tokens: model.max_output_tokens,
              supports_thinking: model.supports_thinking,
              supports_tools: model.supports_tools,
              supports_images: model.supports_images,
              reasoning_efforts: model.reasoning_efforts
            }
          end)

        json(conn, %{object: "list", data: items})

      {:error, :unauthorized} ->
        Errors.unauthorized(conn)
    end
  end

  def chat_completions(conn, params) do
    session_id = extract_session_affinity(conn, params)

    with {:ok, user} <- fetch_user(conn),
         :ok <- check_user_rate_limit(user.id),
         {:ok, requested_model} <- validate_request(params),
         {:ok, [primary | _] = candidates} <-
           AffinityRouter.candidate_channels(user.id, session_id, requested_model) do
      wallet = Ledger.ensure_wallet!(user.id)
      prompt_tokens = TokenizerAndPricing.count_request_prompt_tokens(params)

      global_max =
        Application.get_env(
          :cgc_2046,
          :llm_gateway_max_prompt_tokens,
          @default_max_prompt_tokens
        )

      max_prompt_tokens = min(global_max, Map.get(primary, :context_window, global_max))

      if prompt_tokens > max_prompt_tokens do
        Errors.prompt_too_large_error(conn)
      else
        hold_mc = TokenizerAndPricing.estimate_pre_flight_hold_mc(params, primary, prompt_tokens)

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
                  requested_model,
                  prompt_tokens,
                  hold_mc,
                  held_wallet.hold_id
                )

              {:error, reason} ->
                LeaseManager.release_slot(user.id)
                Errors.hold_error(conn, reason, user.id)
            end

          {:error, :too_many_concurrent_streams} ->
            Errors.concurrency_error(conn)
        end
      end
    else
      {:error, :model_not_found} -> Errors.model_not_found(conn)
      {:error, :no_channels} -> Errors.upstream_unavailable(conn)
      {:error, :unauthorized} -> Errors.unauthorized(conn)
      {:error, :rate_limited} -> Errors.rate_limit_error(conn)
      {:error, :invalid_request} -> Errors.invalid_request(conn)
    end
  end

  @doc false
  def parse_sse_metrics(raw_chunk) when is_binary(raw_chunk) do
    {content_acc, reasoning_acc, usage_acc, _sse_error?} =
      OpenaiAdapter.parse_sse_frames(raw_chunk)

    {content_acc, reasoning_acc, usage_acc}
  end

  defp run_stream(
         conn,
         params,
         user,
         session_id,
         candidates,
         primary,
         requested_model,
         prompt_tokens,
         hold_mc,
         hold_id
       ) do
    start_ms = System.monotonic_time(:millisecond)
    initial_state = LlmGatewayStream.init_state(conn, primary, requested_model)

    try do
      LlmGatewayStream.stream_with_failover(conn, params, candidates, start_ms)
    rescue
      exception ->
        LlmGatewayStream.update_state(%{upstream_error?: true})
        Logger.error("llm gateway stream crashed: #{Exception.message(exception)}")
        reraise exception, __STACKTRACE__
    catch
      {:downstream_closed, closed_conn} ->
        closed_conn
    after
      final_state = LlmGatewayStream.get_state(initial_state)
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

      LlmGatewayStream.delete_state()
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
      {flushed_state, _trailing_out} = LlmGatewayStream.flush_remaining_sse_buffer()
      state = if map_size(flushed_state) > 0, do: flushed_state, else: state

      settlement =
        TokenizerAndPricing.calculate_settlement(
          Map.get(state, :pricing, %{}),
          prompt_tokens,
          state
        )

      usage_attrs =
        Map.merge(settlement, %{
          session_id: session_id,
          logical_model: Map.get(state, :logical_model, "unknown"),
          upstream_channel: Map.get(state, :channel_label, "unknown"),
          upstream_model: Map.get(state, :upstream_model, "unknown"),
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
    model = Map.get(params, "model")
    trimmed_model = if is_binary(model), do: String.trim(model), else: ""

    if trimmed_model != "" and byte_size(trimmed_model) <= @max_model_name_bytes and
         is_list(messages) and messages != [] and length(messages) <= @max_request_messages and
         Enum.all?(messages, &is_map/1) do
      {:ok, trimmed_model}
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
        if is_binary(params["session_id"]) and byte_size(params["session_id"]) > 0,
          do: params["session_id"],
          else: nil
    end
  end
end
