defmodule Cgc2046.Mcp.Tools.CancelOperation do
  @moduledoc """
  确认流内置工具（D-D3）：取消 pending 操作（仅本人、pending）。
  """
  use Anubis.Server.Component, type: :tool, meta: %{workspace_id: :optional}

  alias Cgc2046.Mcp.Confirmation
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:pending_id, {:required, :string}, description: "待取消操作 ID")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "cancel_operation", fn actor, _workspace_id, params ->
        Confirmation.cancel(actor, params["pending_id"] || params[:pending_id])
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end
end
