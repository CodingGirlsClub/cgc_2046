defmodule Cgc2046.Mcp.Tools.ListWorkspaceEvents do
  @moduledoc """
  列出工作台全部活动（role-agent-journeys-v2 S3）——管理工作台面板的可编辑
  活动发现面（list_workspace_courses 同款）。

  `get_my_enrollments` 只回本人报名的活动；`discover_offerings` 仅 open+public，
  不含 draft——管理工作台需要「本台全部活动」的发现面（含 draft）。

  返回：`event_id / title / slug / status / visibility / enrollment_badge /
  starts_at / registration_deadline`（enrollment_badge = R6/KTD1 派生报名状态
  徽章：enrolling|starting_soon|closed|full）。`status` 可选过滤
  （draft|open|closed|cancelled）。按创建时间正序，封顶 100。

  授权 = Wrapper 默认 fail-closed member 门（`list_workspace_courses` 同款）：
  workspace member 可读全部状态（含 draft）——本面读门禁在 Wrapper 层已真实
  发生，活动直读走 `authorize?: false`。
  """

  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Events.Event
  alias Cgc2046.Mcp.Wrapper

  require Ash.Query

  @limit 100

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID(UUID)")

    field(:status, :string, description: "按状态过滤（可选：draft | open | closed | cancelled）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "list_workspace_events", fn _actor, workspace_id, params ->
        with {:ok, status} <- parse_status(params["status"] || params[:status]),
             {:ok, rows} <- read_events(workspace_id, status) do
          {:ok, %{count: length(rows), events: rows}}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 空串/nil = 不过滤；值经 Event.status_values/1 白名单（非法值报错带清单）
  defp parse_status(nil), do: {:ok, nil}
  defp parse_status(""), do: {:ok, nil}

  defp parse_status(status) when is_binary(status) do
    values = Event.status_values()

    case Enum.find(values, &(to_string(&1) == status)) do
      nil ->
        {:error, "invalid status (expected one of #{Enum.map_join(values, "|", &to_string/1)})"}

      atom ->
        {:ok, atom}
    end
  end

  defp parse_status(_), do: {:error, "status must be a string"}

  # member 门已在 Wrapper 层真实发生（非成员 forbidden 落审计）；tenant 锁
  # 工作台归属，authorize?: false 直读全部状态（含 draft）。enrollment_badge
  # 计算列一并 load——状态徽章投影消费（load 依赖 capacity/confirmed_count/
  # starts_at/registration_deadline 由 Ash 补载）。
  defp read_events(workspace_id, status) do
    Event
    |> scope_status(status)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.limit(@limit)
    |> Ash.Query.load(:enrollment_badge)
    |> Ash.read(authorize?: false, tenant: workspace_id)
    |> case do
      {:ok, events} -> {:ok, Enum.map(events, &to_row/1)}
      {:error, _} = err -> err
    end
  end

  # filter 宏不接受任意控制流（if AST 不被识别）——分支在宏外
  defp scope_status(query, nil), do: query
  defp scope_status(query, status), do: Ash.Query.filter(query, status == ^status)

  defp to_row(event) do
    %{
      event_id: event.id,
      title: event.title,
      slug: event.slug,
      status: event.status,
      visibility: event.visibility,
      enrollment_badge: event.enrollment_badge,
      starts_at: event.starts_at,
      registration_deadline: event.registration_deadline
    }
  end
end
