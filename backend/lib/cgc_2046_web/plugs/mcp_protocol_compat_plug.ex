defmodule Cgc2046Web.Plugs.McpProtocolCompatPlug do
  @moduledoc """
  MCP-Protocol-Version 兼容 shim（有界，上游修复后可移除）。

  Why：OpenClacky ≤1.5.6 的 MCP client 对每个请求（含 initialize）硬编码发送
  `MCP-Protocol-Version: 2024-11-05`（openclacky gem client.rb:25 +
  http_transport.rb:91），且忽略 initialize 返回的协商版本（handshake 只读
  serverInfo），旧 header 全程伴随。anubis plug 对「存在但不支持」的版本在协商
  前直接 400（streamable_http/plug.ex `validate_protocol_version_header`）。

  本 plug 仅把恰好为 2024-11-05 的 header 删除，让 anubis 走「header 缺失按
  2025-03-26 放行」的向后兼容路径——OpenClacky 的 transport 实为 2025-03-26
  streamable-http，tools 报文形状跨版本一致。其它任何 header 值原样透传
  （不认识的旧版本仍由 anubis 400，行为不变）。

  禁止的替代方案：把 2024-11-05 加进 `supported_protocol_versions`——
  Anubis Protocol Registry 无该版本协议模块，会 MatchError 崩 session（已验证）。
  """
  @behaviour Plug

  import Plug.Conn

  @legacy_version "2024-11-05"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_req_header(conn, "mcp-protocol-version") do
      [@legacy_version] -> delete_req_header(conn, "mcp-protocol-version")
      _ -> conn
    end
  end
end
