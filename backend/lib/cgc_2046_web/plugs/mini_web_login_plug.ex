defmodule Cgc2046Web.Plugs.MiniWebLoginPlug do
  @moduledoc "Browser proof and verified token claims for mini-program-to-web authorization."
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, _) do
    origin = Application.fetch_env!(:cgc_2046, :web_base_url) |> URI.parse()
    expected = URI.to_string(%URI{scheme: origin.scheme, host: origin.host, port: origin.port})

    browser? =
      conn.method == "POST" and get_req_header(conn, "origin") == [expected] and
        Enum.any?(
          get_req_header(conn, "content-type"),
          &String.starts_with?(&1, "application/json")
        )

    context = conn.private |> Map.get(:absinthe, %{}) |> Map.get(:context, %{})

    context =
      Map.merge(context, %{
        mini_web_browser?: browser?,
        mini_web_claims: verified_claims(conn),
        mini_web_proof: conn.req_cookies["cgc_mp_web_proof"],
        mini_web_ip: conn.remote_ip |> :inet.ntoa() |> to_string()
      })

    absinthe = Map.get(conn.private, :absinthe, %{}) |> Map.put(:context, context)
    conn |> put_private(:absinthe, absinthe) |> put_resp_header("cache-control", "no-store")
  end

  defp verified_claims(%{assigns: %{current_user: %Cgc2046.Accounts.User{} = user}} = conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims, _} <- AshAuthentication.Jwt.verify(token, Cgc2046.Accounts.User),
         true <- claims["sub"] == AshAuthentication.user_to_subject(user) do
      claims
    else
      _ -> %{}
    end
  end

  defp verified_claims(_), do: %{}
end
