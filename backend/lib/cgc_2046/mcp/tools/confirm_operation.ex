defmodule Cgc2046.Mcp.Tools.ConfirmOperation do
  @moduledoc """
  确认流内置工具（D-D3）：确认并执行 pending 操作。

  仅本人、pending 且未过期可确认；确认后调注册执行器落库 + 审计。
  本工具不要求 workspace 成员资格（pending 归属校验即授权，见 Wrapper @workspace_optional）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Mcp.Confirmation
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:pending_id, {:required, :string}, description: "待确认操作 ID（needs_confirmation 返回）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "confirm_operation", fn actor, _workspace_id, params ->
        Confirmation.confirm(actor, params["pending_id"] || params[:pending_id])
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end
end
