defmodule Cgc2046Web.Plugs.DesktopClientGatePlug do
  @moduledoc """
  桌面客户端版本门控与止损开关 Plug（ADR-0027）。

  无状态、零 DB 依赖，挂载在 `:graphql`、`:mcp`（豁免 `DELETE /mcp/token`）
  与 `:llm_gateway`（`desktop_only: true`）最前端（鉴权之前）：
  - 默认仅对 `x-cgc-client: desktop`（单一有效头）生效，不影响 Web / 小程序 / 其它调用方；
  - `desktop_only: true` 时在 `kill_switch` 开启后连无头旧内测包一并拦截；
  - 拒绝统一返回 HTTP `426 Upgrade Required` 与结构化 JSON，与 `401` 鉴权失效物理隔离。
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Cgc2046Web.DesktopRelease

  @telemetry_event [:cgc_2046, :desktop_gate, :rejected]

  @impl true
  def init(opts) do
    %{
      desktop_only: Keyword.get(opts, :desktop_only, false),
      exempt_token_delete: Keyword.get(opts, :exempt_token_delete, false)
    }
  end

  @impl true
  def call(conn, opts) do
    if exempt_request?(conn, opts) do
      conn
    else
      evaluate(conn, opts)
    end
  end

  defp exempt_request?(%Plug.Conn{method: "DELETE", request_path: "/mcp/token"}, %{
         exempt_token_delete: true
       }),
       do: true

  defp exempt_request?(_conn, _opts), do: false

  defp evaluate(conn, opts) do
    cfg = DesktopRelease.config()
    client_version = DesktopRelease.single_header(conn, "x-cgc-client-version")
    client_platform = DesktopRelease.single_header(conn, "x-cgc-client-platform")
    is_desktop = DesktopRelease.single_header(conn, "x-cgc-client") == "desktop"

    decision =
      cond do
        is_desktop ->
          DesktopRelease.evaluate_gate(client_version, cfg)

        opts.desktop_only and cfg.kill_switch ->
          DesktopRelease.evaluate_gate(client_version, cfg)

        true ->
          :allow
      end

    case decision do
      :allow ->
        conn

      {:reject, code, message} ->
        reject(conn, code, message, cfg, client_version, client_platform)
    end
  end

  defp reject(conn, code, message, cfg, client_version, client_platform) do
    :telemetry.execute(@telemetry_event, %{count: 1}, %{
      code: code,
      client_version: client_version,
      client_platform: client_platform,
      path: conn.request_path
    })

    Logger.warning(
      "desktop_client_gate rejected request code=#{code} path=#{conn.request_path} version=#{inspect(client_version)} platform=#{inspect(client_platform)}"
    )

    body =
      Jason.encode!(%{
        error: %{
          code: code,
          message: message,
          min_version: cfg.min_supported_version,
          latest_version: cfg.latest_version,
          download_url: cfg.download_url
        }
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(426, body)
    |> halt()
  end
end
