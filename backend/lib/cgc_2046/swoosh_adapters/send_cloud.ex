defmodule Cgc2046.SwooshAdapters.SendCloud do
  @moduledoc """
  Swoosh adapter for SendCloud's regular mail API.

  The adapter deliberately depends on the existing `Req` dependency instead of
  adding a provider SDK. Tests can pass `req_options: [plug: {Req.Test, stub}]`.
  """

  use Swoosh.Adapter,
    required_config: [:api_user, :api_key, :from, :from_name]

  alias Swoosh.Email

  @base_url "https://api.sendcloud.net"
  @endpoint "/apiv2/mail/send"

  @impl true
  def deliver(%Email{} = email, config \\ []) do
    req =
      [
        base_url: @base_url,
        receive_timeout: 5_000,
        retry: false,
        redirect: false
      ]
      |> Keyword.merge(config[:req_options] || [])
      |> Req.new()

    case Req.post(req, url: @endpoint, form: payload(email, config)) do
      {:ok, %Req.Response{status: status, body: %{"result" => true} = body}}
      when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:send_cloud, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp payload(%Email{} = email, config) do
    %{
      "apiUser" => config[:api_user],
      "apiKey" => config[:api_key],
      "from" => config[:from],
      "fromName" => config[:from_name],
      "to" => recipients(email.to),
      "subject" => email.subject,
      "html" => email.html_body || ""
    }
  end

  defp recipients(recipients) do
    Enum.map_join(recipients, ",", fn
      {_name, address} -> address
      address -> address
    end)
  end
end
