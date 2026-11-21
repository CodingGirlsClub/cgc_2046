defmodule Cgc2046Web.LlmGatewayErrors do
  @moduledoc """
  `/v1/chat/completions` 与 `/v1/models` 的 OpenAI 风格错误信封与上游错误脱敏工具。
  """

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_status: 2]

  alias Cgc2046.LlmGateway.Ledger

  @spec send_error(Plug.Conn.t(), integer(), String.t(), String.t(), String.t(), map()) ::
          Plug.Conn.t()
  def send_error(conn, status, code, type, message, extra \\ %{}) do
    error = Map.merge(%{code: code, type: type, message: message}, extra)
    conn |> put_status(status) |> json(%{error: error})
  end

  def hold_error(conn, :wallet_frozen, user_id) do
    reason =
      try do
        Ledger.fetch_wallet!(user_id).frozen_reason
      rescue
        _ -> nil
      end

    extra =
      if is_binary(reason) and String.trim(reason) != "",
        do: %{reason: reason},
        else: %{}

    send_error(
      conn,
      403,
      "wallet_frozen",
      "permission_error",
      "Your LLM wallet is frozen. Please contact support.",
      extra
    )
  end

  def hold_error(conn, _reason, _user_id) do
    send_error(
      conn,
      402,
      "insufficient_quota",
      "billing_error",
      "Insufficient LLM credits. Please renew your subscription or top up a credit pack."
    )
  end

  def concurrency_error(conn),
    do:
      send_error(
        conn,
        429,
        "concurrency_limit_exceeded",
        "rate_limit_error",
        "Too many concurrent active streams. Please wait for current tasks to finish."
      )

  def rate_limit_error(conn),
    do:
      send_error(
        conn,
        429,
        "rate_limit_exceeded",
        "rate_limit_error",
        "Too many LLM requests. Please slow down."
      )

  def prompt_too_large_error(conn),
    do:
      send_error(
        conn,
        413,
        "context_length_exceeded",
        "invalid_request_error",
        "Prompt exceeds maximum allowed token limit."
      )

  def invalid_request(conn),
    do:
      send_error(
        conn,
        400,
        "invalid_request",
        "invalid_request_error",
        "model and non-empty messages array are required."
      )

  def model_not_found(conn),
    do:
      send_error(
        conn,
        400,
        "model_not_found",
        "invalid_request_error",
        "Model is not available on CGC Gateway."
      )

  def unauthorized(conn),
    do:
      send_error(
        conn,
        401,
        "unauthorized",
        "authentication_error",
        "A valid first-party session bearer token is required."
      )

  def upstream_unavailable(
        conn,
        status \\ 503,
        message \\ "No LLM gateway channels are configured."
      ),
      do: send_error(conn, status, "upstream_unavailable", "upstream_error", message)

  def send_mid_stream_error_frame(conn) do
    frame =
      "data: " <>
        Jason.encode!(%{
          error: %{
            code: "upstream_stream_interrupted",
            message: "Upstream model stream interrupted mid-generation."
          }
        }) <> "\n\n"

    case Plug.Conn.chunk(conn, frame) do
      {:ok, next_conn} -> next_conn
      {:error, _} -> conn
    end
  end

  def classify_upstream_client_error(status, raw_body) do
    {upstream_code, raw_message} = extract_upstream_error(raw_body)

    context_length_exceeded? =
      status == 413 or
        upstream_code == "context_length_exceeded" or
        (is_binary(raw_message) and
           Regex.match?(~r/maximum context length|context_length_exceeded/i, raw_message))

    if context_length_exceeded? do
      {413, "context_length_exceeded",
       sanitize_upstream_message(
         raw_message,
         "Request exceeds the model's maximum context length."
       )}
    else
      {400, "invalid_request",
       sanitize_upstream_message(raw_message, "Upstream rejected the request parameters.")}
    end
  end

  defp extract_upstream_error(raw_body) when is_binary(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{"error" => %{} = error}} ->
        code = if is_binary(error["code"]), do: error["code"], else: nil
        msg = if is_binary(error["message"]), do: error["message"], else: nil
        {code, msg}

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
end
