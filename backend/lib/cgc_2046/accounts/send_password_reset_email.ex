defmodule Cgc2046.Accounts.SendPasswordResetEmail do
  @moduledoc """
  Sends password reset instructions without keeping the request open for mail IO.
  """

  use AshAuthentication.Sender
  require Logger
  import Swoosh.Email

  @telemetry_event [:cgc2046, :password_reset, :send_email]
  @default_web_base_url "http://localhost:3000"
  @default_from "no-reply@example.com"
  @default_from_name "CGC 2046"
  @subject "重置 CGC 2046 密码"

  @doc false
  def send(user, token, _opts \\ []) do
    email = user |> Map.fetch!(:email) |> to_string()

    _ = Task.start(fn -> deliver(email, token) end)
    :ok
  end

  defp deliver(email, token) do
    config = Application.get_env(:cgc_2046, Cgc2046.Mailer, [])
    from = Keyword.get(config, :from, @default_from)
    from_name = Keyword.get(config, :from_name, @default_from_name)
    web_base_url = Application.get_env(:cgc_2046, :web_base_url, @default_web_base_url)
    reset_url = build_reset_url(web_base_url, token)

    message =
      new()
      |> from({from_name, from})
      |> to(email)
      |> subject(@subject)
      |> html_body(body(reset_url))

    case Cgc2046.Mailer.deliver(message) do
      {:ok, _response} -> :ok
      {:error, reason} -> report_failure(email, reason)
      other -> report_failure(email, {:unexpected_result, other})
    end
  rescue
    error -> report_failure(email, error)
  catch
    kind, reason -> report_failure(email, {kind, reason})
  end

  defp build_reset_url(web_base_url, token) do
    base_url = String.trim_trailing(to_string(web_base_url), "/")
    escaped_base_url = Plug.HTML.html_escape(base_url)
    escaped_token = Plug.HTML.html_escape(to_string(token))
    "#{escaped_base_url}/reset-password?token=#{escaped_token}"
  end

  defp body(reset_url) do
    """
    <p>你请求了重置 CGC 2046 账号密码。</p>
    <p>请在 24 小时内点击以下链接完成重置，链接仅可使用一次：</p>
    <p><a href="#{reset_url}">重置密码</a></p>
    <p>如果这不是你的操作，请忽略本邮件。</p>
    <p>CGC 2046</p>
    """
  end

  defp report_failure(email, reason) do
    metadata = %{reason: reason_category(reason), email: mask_email(email)}

    Logger.warning(
      "password reset email delivery failed email=#{metadata.email} reason=#{metadata.reason}"
    )

    :telemetry.execute(@telemetry_event, %{count: 1}, metadata)
    :ok
  end

  defp reason_category(reason) when is_atom(reason), do: reason

  defp reason_category({:send_cloud, status, _body}) when is_integer(status),
    do: :send_cloud_error

  defp reason_category({kind, _reason}) when kind in [:error, :exit, :throw], do: :delivery_failed
  defp reason_category(_reason), do: :delivery_failed

  defp mask_email(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] when local != "" and domain != "" ->
        String.first(local) <> "***@" <> domain

      _ ->
        "***"
    end
  end
end
