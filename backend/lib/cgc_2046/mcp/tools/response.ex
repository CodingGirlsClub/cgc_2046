defmodule Cgc2046.Mcp.Tools.Response do
  @moduledoc """
  工具响应统一出口：`Wrapper.result()` → anubis `execute/2` 返回值。

  - `{:ok, payload}` → JSON 文本响应
  - `{:needs_confirmation, %{pending_id, summary}}` → JSON 文本响应（客户端据此走确认对话，
    再调 `confirm_operation`；D-D3 two-tool 模式，不用 elicitation）
  - `{:error, msg}` → JSON-RPC invalid_request 错误
  """
  alias Anubis.MCP.Error
  alias Anubis.Server.Response

  @spec to_response(Cgc2046.Mcp.Wrapper.result(), Anubis.Server.Frame.t()) ::
          {:reply, Response.t(), Anubis.Server.Frame.t()}
          | {:error, Error.t(), Anubis.Server.Frame.t()}
  def to_response({:ok, payload}, frame) do
    {:reply, Response.text(Response.tool(), Jason.encode!(payload)), frame}
  end

  def to_response({:needs_confirmation, %{pending_id: pending_id, summary: summary}}, frame) do
    payload = %{
      status: "needs_confirmation",
      pending_id: pending_id,
      summary: summary,
      hint:
        "请向用户展示摘要并询问是否确认。用户确认后调用 confirm_operation(pending_id)，取消则调用 cancel_operation(pending_id)。"
    }

    {:reply, Response.text(Response.tool(), Jason.encode!(payload)), frame}
  end

  def to_response({:error, message}, frame) when is_binary(message) do
    {:error, Error.execution(message), frame}
  end
end
