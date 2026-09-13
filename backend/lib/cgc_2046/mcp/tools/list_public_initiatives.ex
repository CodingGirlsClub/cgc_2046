defmodule Cgc2046.Mcp.Tools.ListPublicInitiatives do
  use Anubis.Server.Component, type: :tool, meta: %{workspace_id: :optional, membership: :public}
  alias Cgc2046.Mcp.Wrapper

  schema do
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "list_public_initiatives", fn _actor, _workspace_id, _params ->
        case Cgc2046.Initiatives.Public.list() do
          {:ok, initiatives} -> {:ok, %{initiatives: initiatives, count: length(initiatives)}}
          {:error, _} -> {:error, "failed to list public initiatives"}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end
end
