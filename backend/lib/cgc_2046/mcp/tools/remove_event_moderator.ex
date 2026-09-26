defmodule Cgc2046.Mcp.Tools.RemoveEventModerator do
  @moduledoc """
  移除活动的一名主理人（工作台 Owner/Admin 专属，直接写，不走确认流）。moderator_id 是
  list_event_moderators 返回的记录 id，不是 user_id。非 Owner/Admin 返回 forbidden；记录不存在
  时返回错误。返回 removed + moderator_id。
  """
  use Anubis.Server.Component, type: :tool
  alias Cgc2046.Events.Moderators
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")

    field(:moderator_id, {:required, :string},
      description: "主理人记录 id（取自 list_event_moderators，不是 user_id）"
    )
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
