defmodule Cgc2046.Mcp.Tools.ListAttendances do
  @moduledoc """
  列出某活动的核销记录（#508 残余：场次数据回收；Owner/Admin 管理读工具）。

  数据面 = `Admission.Attendance` read policy（#508 起工作台 Owner/Admin 本租户
  + PlatformAdmin 跨租户）；`event_id` 必填——核销记录天然按场（导出本场数据
  是唯一用例，全工作台汇总走 workspace_payment_stats）。

  行形状（一场核销一行）：attendance 事实（enrollment_id / checked_in_at /
  method：scan|manual / operator）+ 报名人摘要（id/email/display_name，
  `list_enrollments` 同款 authorize?: false 批量投影）+ 报名状态 + 该报名押金单
  状态（order_kind=deposit 的最近单：paid/refunding/refunded/refund_failed/
  forfeited；免费场无单 = nil）——「谁来了 × 押金去向」一屏可对账。

  载荷封顶 100 行 + `total_count` 截断前小计（§B#16 语义，list_enrollments
  同款）。授权：默认 fail-closed member 门 + 工具层 `Rbac.manage?/2` 单源判定。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.{Rbac, User}
  alias Cgc2046.Admission.{Attendance, Enrollment}
  alias Cgc2046.Events.Event
  alias Cgc2046.Mcp.Wrapper
  alias Cgc2046.Repo

  require Ash.Query

  @limit 100

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")

    field(:event_id, {:required, :string},
      description: "活动 ID（UUID，来自 list_workspace_events / discover_offerings）"
    )
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "list_attendances", fn actor, workspace_id, params ->
        event_id = params["event_id"]

        with :ok <- authorize(actor, workspace_id),
             {:ok, event} <- fetch_event(actor, workspace_id, event_id) do
          query =
            Attendance
            |> Ash.Query.filter(event_id == ^event.id)
            |> Ash.Query.sort(checked_in_at: :desc, id: :desc)
            |> Ash.Query.limit(@limit)

          with {:ok, attendances} <- Ash.read(query, actor: actor, tenant: workspace_id),
               {:ok, total_count} <-
                 count_attendances(event.id, workspace_id) do
            rows = to_rows(attendances, workspace_id)

            {:ok,
             %{
               workspace_id: workspace_id,
               event_id: event.id,
               event_title: event.title,
               count: length(rows),
               total_count: total_count,
               attendances: rows
             }}
          else
            {:error, %Ash.Error.Forbidden{}} ->
              {:error, "forbidden: not allowed to list attendances of workspace #{workspace_id}"}

            {:error, _} ->
              {:error, "failed to list attendances"}
          end
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # Owner/Admin 专属：工具层管理角色判定（list_enrollments 同款；PlatformAdmin
  # 走 Rbac.manage? 不认的分支——由域 policy 的 PlatformAdmin 子句兜底放行）
  defp authorize(actor, workspace_id) do
    if Rbac.manage?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: owner or admin required to list attendances"}
    end
  end

  # tenant 收紧活动归属：他租户 event_id 与不存在同一「not found」，不泄露存在性
  defp fetch_event(actor, workspace_id, event_id) do
    case Event
         |> Ash.Query.for_read(:get_by_id, %{id: event_id})
         |> Ash.read_one(actor: actor, tenant: workspace_id) do
      {:ok, nil} ->
        {:error, "event not found: #{event_id}"}

      {:ok, event} ->
        {:ok, event}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: not allowed to read event #{event_id}"}

      {:error, _} ->
        {:error, "failed to load event"}
    end
  end

  # 截断前小计（§B#16）：与列表同 scope（event），不计 limit
  defp count_attendances(event_id, workspace_id) do
    Attendance
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.count(tenant: workspace_id, actor: nil, authorize?: false)
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, _} -> {:error, "failed to count attendances"}
    end
  end

  # 一屏对账装配：attendance ×（报名状态 + 押金单状态 + 双方用户摘要）。
  # 报名/订单读取 authorize?: false——授权已在工具层 + Attendance read 完成，
  # 行数据全部限定在本场 attendance 的 enrollment 集合内（load_enrollees 同纪律）。
  defp to_rows(attendances, workspace_id) do
    enrollment_ids = attendances |> Enum.map(& &1.enrollment_id) |> Enum.uniq()

    enrollments = load_enrollments(enrollment_ids)
    deposit_orders = load_deposit_orders(enrollment_ids, workspace_id)

    # 报名人（经 enrollment）+ 核销操作人两路摘要的并集
    user_ids =
      (Enum.map(enrollments, & &1.user_id) ++
         Enum.map(attendances, & &1.operator_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    users = load_users(user_ids)

    Enum.map(attendances, fn attendance ->
      enrollment = enrollment_by_id(enrollments, attendance.enrollment_id)
      order = Map.get(deposit_orders, attendance.enrollment_id)

      %{
        enrollment_id: attendance.enrollment_id,
        user: user_summary(users, enrollment && enrollment.user_id),
        enrollment_status: enrollment && to_string(enrollment.status),
        deposit_order_status: order && to_string(order),
        checked_in_at: attendance.checked_in_at,
        method: to_string(attendance.method),
        operator: user_summary(users, attendance.operator_id)
      }
    end)
  end

  defp load_enrollments([]), do: []

  defp load_enrollments(enrollment_ids) do
    Enrollment
    |> Ash.Query.filter(id in ^enrollment_ids)
    |> Ash.read!(authorize?: false)
  end

  # 该批报名的押金单（order_kind=deposit）：活跃单优先（部分唯一索引保证至多
  # 一条非终态），否则最近一条终态单——attendance.ex 的 active_deposit_order/1
  # 同语义的批量版；无单（免费场）= nil。
  defp load_deposit_orders([], _workspace_id), do: %{}

  defp load_deposit_orders(enrollment_ids, _workspace_id) do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT DISTINCT ON (enrollment_id) enrollment_id, status
        FROM payments_orders
        WHERE enrollment_id IN (SELECT unnest($1::uuid[]))
          AND order_kind = 'deposit'
        ORDER BY enrollment_id,
          (status IN ('pending','paid','refunding','refund_failed')) DESC,
          updated_at DESC
        """,
        [Enum.map(enrollment_ids, &Repo.uuid!/1)]
      )

    Map.new(rows, fn [enrollment_id, status] ->
      {Ecto.UUID.load!(enrollment_id), status}
    end)
  end

  defp load_users([]), do: %{}

  defp load_users(user_ids) do
    user_ids
    |> Enum.uniq()
    |> Enum.reject(&is_nil/1)
    |> then(&(User |> Ash.Query.filter(id in ^&1) |> Ash.read!(authorize?: false)))
    |> Map.new(fn user -> {user.id, user} end)
  end

  defp enrollment_by_id(enrollments, enrollment_id) do
    Enum.find(enrollments, &(&1.id == enrollment_id))
  end

  # id/email/display_name 三字段（list_enrollments 同口径）
  defp user_summary(_users, nil), do: nil

  defp user_summary(users, user_id) do
    case Map.get(users, user_id) do
      nil ->
        %{id: user_id, email: nil, display_name: nil}

      user ->
        %{
          id: user.id,
          email: user.email && to_string(user.email),
          display_name: user.display_name
        }
    end
  end
end
