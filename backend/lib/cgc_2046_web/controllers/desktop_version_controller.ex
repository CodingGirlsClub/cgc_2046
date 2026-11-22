defmodule Cgc2046Web.DesktopVersionController do
  @moduledoc """
  免鉴权、零 DB 的桌面客户端轻量版本检查端点：`GET /api/desktop/version`。
  """

  use Cgc2046Web, :controller

  alias Cgc2046Web.DesktopRelease

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    client_version =
      DesktopRelease.single_header(conn, "x-cgc-client-version") ||
        DesktopRelease.normalize_blank(params["version"])

    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(DesktopRelease.version_status(client_version))
  end
end
