defmodule Cgc2046Web.RequireAuth do
  @moduledoc """
  强制认证 plug:请求必须携带已认证用户(`conn.assigns[:current_user]`),
  否则返回 401 JSON。

  与 `AuthPlug.load_from_bearer` 配合:先加载,再检查;仅对需要认证的
  端点(如 `/api/v1/*`)挂载,公开端点(GraphQL signIn/signUp)不挂。
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, Jason.encode!(%{errors: %{detail: "Unauthorized"}}))
      |> halt()
    end
  end
end
