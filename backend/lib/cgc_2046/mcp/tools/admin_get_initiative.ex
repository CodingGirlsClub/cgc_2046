defmodule Cgc2046.Mcp.Tools.AdminGetInitiative do
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
