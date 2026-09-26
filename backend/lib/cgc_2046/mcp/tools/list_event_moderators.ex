defmodule Cgc2046.Mcp.Tools.ListEventModerators do
  @moduledoc """
  列出活动主理人（Owner/Admin 专属读）。

  回显平铺（#539，域层 `Moderators.list` 已 load）：`user_display_name` 未设置时
  为 null，`user_member_number` 恒有值——同 Web 侧 fallback 链数据面，
  agent 可回读「指给了谁」。
  """
  use Anubis.Server.Component, type: :tool
  alias Cgc2046.Events.Moderators
  alias Cgc2046.Mcp.Wrapper

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    工作台 Owner/Admin 专用：列出一场活动的主理人。每条含记录 id（移除时作为 remove_event_moderator 的
    moderator_id）、user_id、user_display_name（未设置时为 null）和 user_member_number（CGC 编号，
    恒有值），可据此告诉用户指派给了谁。
    """
  end

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:event_id, {:required, :string}, description: "目标活动 ID（UUID）")
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

  # 回显字段域层已 load（@display_calculations），平铺投影零额外查询；
  # display_name 可空原样 null，member_number 由 uuid 现算恒非空（#537/#539）
  defp row(record),
    do: %{
      id: record.id,
      event_id: record.event_id,
      user_id: record.user_id,
      user_display_name: record.user_display_name,
      user_member_number: record.user_member_number,
      assigned_by: record.assigned_by,
      assigned_by_display_name: record.assigned_by_display_name,
      assigned_by_member_number: record.assigned_by_member_number,
      assigned_at: record.assigned_at
    }
end
