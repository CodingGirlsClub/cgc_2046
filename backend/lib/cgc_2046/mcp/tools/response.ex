defmodule Cgc2046.Mcp.Tools.Response do
  @moduledoc """
  工具响应统一出口：`Wrapper.result()` → anubis `execute/2` 返回值。

  - `{:ok, payload}` → JSON 文本响应
  - `{:needs_confirmation, %{pending_id, summary}}` → JSON 文本响应（客户端据此走确认对话，
    再调 `confirm_operation`；D-D3 two-tool 模式，不用 elicitation）
  - `{:error, msg}` → JSON-RPC invalid_request 错误

  **全函数**（#631）：第二条 `{:error, error}` 子句兜住**非二进制**错误——工具漏分类的
  域错误/裸异常也必须变成有文案的 JSON-RPC error，而不是 `FunctionClauseError` 把调用
  打崩（`Wrapper.run/3` 会把非二进制错误原样交回本层，见 `database_error_test` 的裸
  `%Postgrex.Error{}` 用例）。正常路径由各工具经 `Mcp.Errors.message/2` 自行分类。
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
        "请向用户展示摘要，并用宿主内置 ask_user 弹卡片让用户点击选择：点「确认执行」后调用 confirm_operation(pending_id)，点「取消」调用 cancel_operation(pending_id)；无人在场（auto_reply）一律按取消处理。"
    }

    {:reply, Response.text(Response.tool(), Jason.encode!(payload)), frame}
  end

  def to_response({:error, message}, frame) when is_binary(message) do
    {:error, Error.execution(message), frame}
  end

  # 兜底（#631）：工具漏分类的非二进制错误（域错误树/裸异常）→ 经统一出口取文案，
  # 不再是 FunctionClauseError。此路径不应被触发（各工具已分类），它的存在是
  # 「响应层全函数」的结构保证。
  def to_response({:error, error}, frame) do
    {:error, Error.execution(Cgc2046.Mcp.Errors.message(error, "tool call failed")), frame}
  end
end
