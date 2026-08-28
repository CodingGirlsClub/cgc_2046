defmodule Cgc2046.Workers.PaymentExpiryWorker do
  @moduledoc """
  支付超时释放 worker（U8/KTD5；Oban cron 每分钟一拍，见 config.exs）。

  R8/F2 超时链：`expire_at` 过点未付的 pending 订单 → 走 `Order :expire` 领域
  action，同事务三联动——订单 CAS expired → 报名 CAS payment_pending→expired →
  名额回落（confirmed_count-1）。名额回池后可重新报名；订单过期后渠道侧迟到
  扣款由落账 worker 的自动退款链处理（AE2，KTD12）。

  复刻 `ApprovalExpiryWorker` 模式（@expiry_specs 声明式规格 + SQL 下推过滤 +
  per-record :expire + 单记录失败 warning 跳过）：

  - 扫描规格单条：`status=pending 且 expire_at < now`（列非空守卫：expire_at
    不可空，schema 层保证；SQL 下推不退化为全表 load）。
  - 与落账 worker 同秒竞态由双方 CAS 天然裁决：任一先落（mark_paid / expire），
  另一方 num_rows=0 被状态守卫拒绝，记 warning 跳过即可（预期竞态）。

  D-A6 纪律：状态转换只走领域 action（强一致路径 + 同事务联动），不裸写
  Ecto UPDATE。Order 多租户 `global?(true)`，跨租户读无需逐 tenant 迭代。
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 3,
    # 唯一窗与 cron 周期（1 分钟）对齐（KTD5）：防抖重复入队/手动重触造成的
    # 并发双拍；拍内转换本身幂等（CAS 终态守卫），唯一任务是第二层。
    unique: [period: 60, states: :incomplete]

  require Ash.Query
  require Logger

  import Ash.Expr, only: [ref: 1]

  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Payments.NotificationTemplates, as: Templates
  alias Cgc2046.Payments.Order

  # 过期扫描声明式规格：Order pending + expire_at < now（SQL 下推过滤）。
  @expiry_specs [
    %{resource: Order, status: :pending, deadline: {:column, :expire_at}, tenant: true}
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    expired =
      Enum.map(@expiry_specs, fn spec ->
        {spec.resource, sweep(spec, now)}
      end)

    if Enum.any?(expired, fn {_resource, count} -> count > 0 end) do
      summary =
        expired
        |> Enum.map(fn {resource, count} -> "#{count} #{kind(resource)}(s)" end)
        |> Enum.join(", ")

      Logger.info("payment expiry sweep: #{summary} expired")
    end

    :ok
  end

  # 列实体：SQL 下推过滤（status + 列非空 + 列 < now），不退化为全表 load。
  defp sweep(%{resource: resource, status: status, deadline: {:column, column}}, now) do
    resource
    |> Ash.Query.filter(status == ^status and not is_nil(^ref(column)) and ^ref(column) < ^now)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(0, fn record, acc ->
      case expire_record(record) do
        :ok -> acc + 1
        :skip -> acc
      end
    end)
  end

  defp kind(resource), do: resource |> Module.split() |> List.last() |> Macro.underscore()

  # 单个记录转换失败不中断整拍：并发终态变化（mark_paid / refund / 手动取消
  # 先落库）会被状态守卫拒绝，属预期竞态，记 warning 跳过即可。
  defp expire_record(%Order{} = order) do
    order
    |> Ash.Changeset.for_update(:expire, %{})
    |> Ash.update(tenant: order.workspace_id, authorize?: false)
    |> handle_expire_result("order", order.id)
    |> tap_expired_notification(order)
  end

  # U5/R13：成功过期 → 学员（名额已释放；截止未过才提示可重报）+ 组织者
  # （该笔待付已失效）各一条。尽力而为：构建/入队失败记 warning 不影响释放。
  defp tap_expired_notification(:ok, order) do
    notify_expired(order)
    :ok
  end

  defp tap_expired_notification(other, _order), do: other

  defp notify_expired(order) do
    case Ash.get(Enrollment, order.enrollment_id, authorize?: false) do
      {:ok, enrollment} ->
        with {:ok, loaded} <- Ash.load(enrollment, [:target_title]) do
          recipients =
            %{enrollment.user_id => Cgc2046.Notifications.Fanout.identities(enrollment.user_id)}
            |> Map.merge(Cgc2046.Notifications.Fanout.managers(order.workspace_id))

          Cgc2046.Notifications.Fanout.deliver(
            recipients,
            Templates.payment_expired(),
            Templates.expiry_data(order, loaded.target_title, registration_open?(loaded)),
            %{"idempotency_key" => Templates.payment_expired() <> ":" <> order.id}
          )
        else
          {:error, reason} ->
            Logger.warning(
              "payment expiry: notify skipped for order #{order.id}: #{inspect(reason)}"
            )
        end

      # review F8：报名读取失败（DB 瞬断等）不 crash 通知链——订单已 expired
      # 终态，重试不重选本单，warning 落日志保可观测。
      {:error, reason} ->
        Logger.warning(
          "payment expiry: notify skipped for order #{order.id}: enrollment read failed #{inspect(reason)}"
        )
    end
  end

  # R13 不承诺语义：报名截止已过 → false（学员文案不含「可重新报名」）。
  defp registration_open?(%{event_id: event_id}) when is_binary(event_id) do
    deadline_open?(Cgc2046.Events.Event, event_id)
  end

  defp registration_open?(%{course_id: course_id}) when is_binary(course_id) do
    deadline_open?(Cgc2046.Courses.Course, course_id)
  end

  defp registration_open?(_), do: false

  # review F8：过期成功后通知构建失败（如 target_title 加载异常）不再吞为静默
  # ——上抛走 Oban 重试；但订单已 expired（终态），重选不中本单，故通知失败
  # 只记 warning 落日志（保留既有尽力而为语义），expire 主体不回滚。
  defp handle_expire_result(result, kind, id) do
    case result do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.warning("payment expiry: #{kind} #{id} expire skipped: #{inspect(error)}")
        :skip
    end
  end

  # review F8：nil deadline = 永开放（ApprovalDeadline.not_expired? nil→true 同语义）；
  # 非 open 状态（已取消/结束）不可再报名——re_enrollable 只在 open 且未截止时 true。
  defp deadline_open?(resource, id) do
    case Ash.get(resource, id, authorize?: false) do
      {:ok, %{status: :open, registration_deadline: nil}} ->
        true

      {:ok, %{status: :open, registration_deadline: deadline}} ->
        DateTime.compare(deadline, DateTime.utc_now()) == :gt

      _ ->
        false
    end
  end
end
