defmodule Cgc2046.Mcp.Tools.CancelOperation do
  @moduledoc """
  确认流内置工具（D-D3）：取消 pending 操作（仅本人、pending）。
  """
  use Anubis.Server.Component, type: :tool, meta: %{workspace_id: :optional}

  alias Cgc2046.Mcp.Confirmation
  alias Cgc2046.Mcp.Wrapper

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    取消一个待确认的操作（pending_id 来自其他工具返回的 needs_confirmation）。只能取消本人发起、
    仍处于待确认状态的操作；取消后该操作不会执行。
    """
  end

  schema do
    field(:pending_id, {:required, :string}, description: "待取消操作 ID")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "cancel_operation", fn actor, _workspace_id, params ->
        Confirmation.cancel(actor, params["pending_id"])
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end
end
