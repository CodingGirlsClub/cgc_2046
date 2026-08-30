defmodule Cgc2046.Mcp.Tools.ListWorkspaceOrders do
  @moduledoc """
  列出本工作台的支付订单（role-agent-journeys-v2 S3，Owner/Admin 管理读工具）。

  数据面同 GraphQL workspaceOrders（同 `Payments.Order :workspace_orders` read
  action，R24 管理面；金额/状态/档位/报名人信息经计算字段下钻——tier_name /
  enrollment_status / learner_email / event_id / course_id）。可选 course_id
  过滤 = 活动维度（course_id 计算字段过滤，GraphQL filter 同源）。

  授权锚 = workspace：默认 fail-closed member 门之外，本工具层再做 Owner/Admin
  判定（`Role.manage_role?/1`），非管理角色成员快速拒绝并落 ToolCallLog 审计；
  读 policy（workspace_orders 仅 Owner/Admin 本租户 + PlatformAdmin）兜底。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.{MembershipContext, Role}
  alias Cgc2046.Mcp.Wrapper
  alias Cgc2046.Payments.Order

  require Ash.Query

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:course_id, :string, description: "按课程过滤（UUID，可选；缺省 = 全工作台订单）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "list_workspace_orders", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]

        with :ok <- authorize(actor, workspace_id) do
          # read（非 bang）+ 错误分类：Forbidden 等错误也落 ToolCallLog 审计。
          # workspace_orders 强制分页（PaginationRequired 拒绝 page: false）：
          # 取 keyset 首页（limit 200），不搬 GraphQL 的游标分页——管理面紧凑
          # 列表一次够看；超出时 more: true 让调用方知情（走 web 管理页深挖）
          Order
          |> Ash.Query.for_read(:workspace_orders, %{workspace_id: workspace_id})
          |> maybe_filter_course(course_id)
          |> Ash.Query.load([
            :tier_name,
            :enrollment_status,
            :learner_email,
            :event_id,
            :course_id
          ])
          |> Ash.read(actor: actor, page: [limit: 200])
          |> case do
            {:ok, %Ash.Page.Keyset{results: orders, more?: more?}} ->
              {:ok,
               %{
                 workspace_id: workspace_id,
                 course_id: course_id,
                 count: length(orders),
                 more: more?,
                 orders: Enum.map(orders, &to_row/1)
               }}

            {:error, %Ash.Error.Forbidden{}} ->
              {:error, "forbidden: not allowed to list orders of workspace #{workspace_id}"}

            {:error, _} ->
              {:error, "failed to list orders"}
          end
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # Owner/Admin 专属（S3）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if actor |> MembershipContext.role_names(workspace_id) |> Enum.any?(&Role.manage_role?/1) do
      :ok
    else
      {:error, "forbidden: owner or admin required to list orders"}
    end
  end

  defp maybe_filter_course(query, nil), do: query
  defp maybe_filter_course(query, course_id), do: Ash.Query.filter(query, course_id == ^course_id)

  defp to_row(order) do
    %{
      order_id: order.id,
      enrollment: %{
        enrollment_id: order.enrollment_id,
        learner_email: order.learner_email,
        enrollment_status: order.enrollment_status && to_string(order.enrollment_status)
      },
      offering: %{event_id: order.event_id, course_id: order.course_id},
      tier_name: order.tier_name,
      amount_cents: order.amount_cents,
      provider: to_string(order.provider),
      status: to_string(order.status),
      inserted_at: order.inserted_at
    }
  end
end
