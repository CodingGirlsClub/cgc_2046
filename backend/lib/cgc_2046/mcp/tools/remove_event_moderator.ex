defmodule Cgc2046.Mcp.Tools.RemoveEventModerator do
  use Anubis.Server.Component, type: :tool
  alias Cgc2046.Events.Moderators
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string})
    field(:moderator_id, {:required, :string})
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "remove_event_moderator", fn actor, workspace_id, params ->
        case Moderators.remove(params["moderator_id"], workspace_id, actor) do
          :ok -> {:ok, %{removed: true, moderator_id: params["moderator_id"]}}
          {:error, :forbidden} -> {:error, "forbidden: owner or admin required"}
          {:error, _} -> {:error, "moderator not found or removal failed"}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end
end
