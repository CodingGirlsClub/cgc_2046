defmodule Cgc2046.Mcp.Tools.ListWorkspaceEvents do
  @moduledoc """
  列出工作台全部活动（role-agent-journeys-v2 S3）——管理工作台面板的可编辑
  活动发现面（list_workspace_courses 同款）。

  `get_my_enrollments` 只回本人报名的活动；`discover_offerings` 仅 open+public，
  不含 draft——管理工作台需要「本台全部活动」的发现面（含 draft）。

  返回：`event_id / title / slug / status / visibility / enrollment_badge /
  starts_at / registration_deadline`（enrollment_badge = R6/KTD1 派生报名状态
  徽章：enrolling|starting_soon|closed|full）+ 缴费槽 `payment_mode`
  （free|pricing|deposit）+ 押金明细 `deposit`（enabled / amount_cents /
  refundable_on_check_in，#586）+ 解除挂载来源标记 `detached_rule_provenance`
  （#630；无标记 null）——押金场读 `payment_mode`，不得从「无定价档且无定价
  开关」推断免费。`status` 可选过滤（draft|open|closed|cancelled）。按创建时间
  正序，封顶 100。

  `detached_rule_provenance` 形状同 GraphQL `Event.detachedRuleProvenance`
  （`%{initiative => %{id,name,slug}, fields => %{<event_field> => %{value,
  source: "locked"}}}`），仅活动被 detach 后非 nil，挂载中 / 从未挂载为 nil
  （agent 无需判键是否存在）。

  授权 = Wrapper 成员门 + 领域 actor 读：普通成员仅 open/closed，管理者按领域权限读取。
  """

  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Events.Event
  alias Cgc2046.Mcp.Wrapper

  require Ash.Query

  @limit 100

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    List events visible to the caller in a workspace. Members can read open/closed events;
    owners/admins can read all statuses. Optional status filter: draft | open | closed | cancelled.
    Returns event_id, title, slug, status, visibility, enrollment_badge, starts_at,
    registration_deadline, payment_mode, deposit and detached_rule_provenance (null when absent).
    Use payment_mode to distinguish free, pricing and deposit events. Ordered by creation, up to
    100 rows.
    """
  end

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID(UUID)")

    field(:status, :string, description: "按状态过滤（可选：draft | open | closed | cancelled）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "list_workspace_events", fn actor, workspace_id, params ->
        with {:ok, status} <- parse_status(params["status"]),
             {:ok, rows} <- read_events(actor, workspace_id, status) do
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

  # 成员门之后继续走领域 actor 读，状态过滤不能扩大 actor 的可见集合。
  defp read_events(actor, workspace_id, status) do
    Event
    |> scope_status(status)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.limit(@limit)
    |> Ash.Query.load(:enrollment_badge)
    |> Ash.read(actor: actor, tenant: workspace_id)
    |> case do
      {:ok, events} -> {:ok, Enum.map(events, &to_row/1)}
      {:error, _} = err -> err
    end
  end

  # filter 宏不接受任意控制流（if AST 不被识别）——分支在宏外
  defp scope_status(query, nil), do: query
  defp scope_status(query, status), do: Ash.Query.filter(query, status == ^status)

  defp to_row(event) do
    Map.merge(
      %{
        event_id: event.id,
        title: event.title,
        slug: event.slug,
        status: event.status,
        visibility: event.visibility,
        enrollment_badge: event.enrollment_badge,
        starts_at: event.starts_at,
        registration_deadline: event.registration_deadline,
        # #630：恒在（无标记 nil）——detach 来源标记的读面（本工具是唯一面向
        # 管理 agent 的活动读面）。
        detached_rule_provenance: event.detached_rule_provenance
      },
      # 缴费槽三态 + 押金明细（#586）：管理面同样不得把押金场读成免费/定价场。
      Cgc2046.Mcp.Tools.PaymentSlot.projection(event)
    )
  end
end
