defmodule Cgc2046.Mcp.Tools.AdminGetInitiative do
  @moduledoc """
  平台管理员专用：按 id 读取单个倡导活动（任意状态，含 draft）及其全部规则。返回活动行：
  id / name / slug / url / hashtag / description / window_starts_at / window_ends_at / status /
  created_by / rules（每条 id / key / value / locked）。公开浏览用 list_public_initiatives。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Mcp.Wrapper
  alias Cgc2046.Mcp.Tools.AdminInitiativeHelpers, as: H

  schema do
    field(:initiative_id, {:required, :string}, description: "Initiative UUID")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_get_initiative", fn actor, _ws, params ->
        H.get(params["initiative_id"], actor)
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end
end
