defmodule Cgc2046.Mcp.Tools.ListEventModerators do
  use Anubis.Server.Component, type: :tool
  alias Cgc2046.Events.Moderators
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string})
    field(:event_id, {:required, :string})
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "list_event_moderators", fn actor, workspace_id, params ->
        case Moderators.list(params["event_id"], workspace_id, actor) do
          {:ok, rows} -> {:ok, %{moderators: Enum.map(rows, &row/1), count: length(rows)}}
          {:error, _} -> {:error, "event not found or not accessible"}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  defp row(record),
    do: %{
      id: record.id,
      event_id: record.event_id,
      user_id: record.user_id,
      assigned_by: record.assigned_by,
      assigned_at: record.assigned_at
    }
end
