defmodule Cgc2046.Mcp.Tools.AssignEventModerator do
  use Anubis.Server.Component, type: :tool
  alias Cgc2046.Events.Moderators
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string})
    field(:event_id, {:required, :string})
    field(:user_id, {:required, :string})
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "assign_event_moderator", fn actor, workspace_id, params ->
        case Moderators.assign(params["event_id"], workspace_id, params["user_id"], actor) do
          {:ok, record} ->
            {:ok, %{moderator_id: record.id, event_id: record.event_id, user_id: record.user_id}}

          {:error, :forbidden} ->
            {:error, "forbidden: owner or admin required"}

          {:error, error} ->
            {:error, Cgc2046.Mcp.Errors.message(error, "failed to assign moderator")}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end
end
