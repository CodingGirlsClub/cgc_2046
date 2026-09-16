defmodule Cgc2046.Mcp.Tools.GetMyEnrollments do
  @moduledoc """
  本人全部报名（role-agent-journeys-v2 S7，R32/R35/AE8；全状态、跨工作台、
  actor 锚定读，不收参数）。

  meta `%{workspace_id: :optional, membership: :deferred}` 命中 Wrapper 的
  `:optional` 分支（discover_offerings 同款跨工作台语义；Enrollment read
  policy `user_id == ^actor(:id)` 本人锚定，无越权面）。

  供给标题/slugs 经 `authorize?: false` 批量投影（先例 = Enrollment.target_title
  计算字段：本人报名锚定的供给段收窄，标题非敏感面）；宿主 workspace 块带
  actor 走 policy（invite_only 工作台对非成员落 nil——跨台报名的可能宿主）。
  行附 `workspace_id` 原值（enrollment 自身列，advisor F4 动作安全作用域——
  展示块 redact 不影响课程面板打开详情的作用域驱动）。

  行附三件资金口径（#622，带 actor 本人订单）：

  - `payment_mode`（free|pricing|deposit）：供给物**现行配置**，单源
    `Offering.payment_mode/1`；供给物不可得 → `nil`，**绝不落 "free"**（#586
    「无信号 + 金额缺失被读成免费」的病根在列表面的复现口）；
  - `order_kind`（enrollment|deposit）：最新一笔订单的**事实**语义；无订单 → nil；
  - `tier_snapshot`：该订单下单时的资金快照（金额/档位名；押金单的 name 是
    合成展示名「押金」，**不得据展示名反推语义**）。

  **现行配置与订单事实刻意并存、不得混读**：活动事后关押金 → `payment_mode`
  变 "free"，但存量已付押金单仍是 deposit 单（到场仍退）。复述某笔报名的资金/
  退改口径以 `order_kind`/`tier_snapshot` 为准；押金明细金额走
  `get_enrollment_summary`（列表行不并列「现行金额 vs 下单快照金额」两个数）。

  最多 100 条（§B#16 读面封顶）。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :deferred}

  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Courses.Course
  alias Cgc2046.Events.Event
  alias Cgc2046.Mcp.Wrapper
  alias Cgc2046.Offering
  alias Cgc2046.Payments.Order

  require Ash.Query

  @limit 100

  schema do
    %{}
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "get_my_enrollments", fn actor, _workspace_id, _params ->
        with {:ok, enrollments} <- read_my_enrollments(actor),
             {:ok, total_count} <- count_my_enrollments(actor),
             {:ok, offerings} <- load_offerings(enrollments),
             {:ok, workspaces} <- load_workspaces(actor, enrollments),
             {:ok, orders} <- load_latest_orders(actor, enrollments) do
          {:ok,
           %{
             enrollments: Enum.map(enrollments, &to_row(&1, offerings, workspaces, orders)),
             count: length(enrollments),
             total_count: total_count
           }}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 截断前总数（§B#16：total_count 为截断前小计——advisor F3；行载荷维持
  # 100 上限，>100 时消费者据 total_count 判定截断页非全集）
  defp count_my_enrollments(actor) do
    Enrollment
    |> Ash.Query.filter(user_id == ^actor.id)
    |> Ash.count(authorize?: false)
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, _} -> {:error, "failed to count enrollments"}
    end
  end

  # 本人报名全状态（带 actor 走 policy，user_id == actor 收窄）；倒序 + 上限。
  # read（非 bang）纪律同 list_public_offerings：失败走 Wrapper 审计不逃逸。
  defp read_my_enrollments(actor) do
    Enrollment
    |> Ash.Query.filter(user_id == ^actor.id)
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(@limit)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, enrollments} -> {:ok, enrollments}
      {:error, _} -> {:error, "failed to load enrollments"}
    end
  end

  # 供给物投影批量读：%{kind => %{offering_id => %{title, slug}}}。
  # authorize?: false 先例 = Enrollment.target_title 计算字段（本人报名锚定投影）。
  defp load_offerings(enrollments) do
    ids_by_kind = %{
      event: enrollments |> Enum.map(& &1.event_id) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      course: enrollments |> Enum.map(& &1.course_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    }

    [event: Event, course: Course]
    |> Enum.reduce_while({:ok, %{}}, fn {kind, resource}, {:ok, acc} ->
      case read_offering_titles(resource, Map.fetch!(ids_by_kind, kind)) do
        {:ok, rows} -> {:cont, {:ok, Map.put(acc, kind, rows)}}
        {:error, _} -> {:halt, {:error, "failed to load offerings"}}
      end
    end)
  end

  defp read_offering_titles(_resource, []), do: {:ok, %{}}

  defp read_offering_titles(resource, ids) do
    resource
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, records} -> {:ok, Map.new(records, &{&1.id, offering_row(&1)})}
      {:error, _} = error -> error
    end
  end

  # 供给物投影：标题/slug + 现行缴费槽三态（#586 单源 Offering.payment_mode/1，
  # 每供给物求值一次，不给每行重复求值）。
  defp offering_row(offering) do
    %{
      title: offering.title,
      slug: offering.slug,
      payment_mode: to_string(Offering.payment_mode(offering))
    }
  end

  # 宿主工作台块：带 actor 的 policy 授权批量读（invite_only 对非成员落 nil）。
  defp load_workspaces(actor, enrollments) do
    ids = enrollments |> Enum.map(& &1.workspace_id) |> Enum.uniq()

    Workspace
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, workspaces} -> {:ok, Map.new(workspaces, &{&1.id, &1})}
      {:error, _} -> {:error, "failed to load workspaces"}
    end
  end

  # 每报名最新一笔订单（inserted_at desc 首条）：%{enrollment_id => order}（带 actor
  # 本人订单）。行内由该单派生 order_kind（语义）与 tier_snapshot（下单时快照）——
  # 注意口径是「最新一笔」，与 get_order_status 的「非终态优先」不同（本面无支付动作，
  # 只复述最近一笔的资金事实）。
  defp load_latest_orders(actor, enrollments) do
    ids = Enum.map(enrollments, & &1.id)

    Order
    |> Ash.Query.filter(enrollment_id in ^ids)
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, orders} ->
        {:ok, orders |> Enum.uniq_by(& &1.enrollment_id) |> Map.new(&{&1.enrollment_id, &1})}

      {:error, _} ->
        {:error, "failed to load orders"}
    end
  end

  defp to_row(enrollment, offerings, workspaces, orders) do
    {kind, offering_id} = kind_and_offering_id(enrollment)
    offering = get_in(offerings, [kind, offering_id])
    order = Map.get(orders, enrollment.id)

    %{
      id: enrollment.id,
      kind: to_string(kind),
      offering: %{
        id: offering_id,
        title: offering && offering.title,
        slug: offering && offering.slug
      },
      workspace_id: enrollment.workspace_id,
      workspace: workspace_block(Map.get(workspaces, enrollment.workspace_id)),
      status: to_string(enrollment.status),
      # 供给物现行缴费槽（供给物不可得 → nil，绝不落 "free"）
      payment_mode: offering && offering.payment_mode,
      # 最新一笔订单的事实：语义（enrollment|deposit）+ 下单时资金快照；无订单 → nil
      order_kind: order && to_string(order.order_kind),
      tier_snapshot: order && tier_snapshot(order.tier_snapshot),
      inserted_at: enrollment.inserted_at
    }
  end

  defp kind_and_offering_id(%{event_id: event_id}) when is_binary(event_id),
    do: {:event, event_id}

  defp kind_and_offering_id(%{course_id: course_id}) when is_binary(course_id),
    do: {:course, course_id}

  defp workspace_block(nil), do: nil

  defp workspace_block(workspace),
    do: %{id: workspace.id, name: workspace.name, slug: workspace.slug}

  # 空快照（免费/占位订单无档位）归一为 nil
  defp tier_snapshot(snapshot) when is_map(snapshot) and map_size(snapshot) > 0, do: snapshot
  defp tier_snapshot(_snapshot), do: nil
end
