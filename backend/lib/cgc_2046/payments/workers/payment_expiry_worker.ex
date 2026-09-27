defmodule Cgc2046.Payments.Workers.PaymentExpiryWorker do
  @moduledoc """
  支付超时释放 worker（U8/KTD5；Oban cron 每分钟一拍，见 config.exs）。

  R8/F2 超时链：`expire_at` 过点未付的 pending 订单 → 走 `Order :expire` 领域
  action，同事务三联动——订单 CAS expired → 报名 CAS payment_pending→expired →
  名额回落（账本 occupancy-1,capacity.synced 信号投影 confirmed_count）。名额回池后可重新报名；订单过期后渠道侧迟到
  扣款由落账 worker 的自动退款链处理（AE2，KTD12）。

  复刻 `ApprovalExpiryWorker` 模式（@expiry_specs 声明式规格 + SQL 下推过滤 +
  per-record :expire + 单记录失败 warning 跳过）：

  - 扫描规格单条：`status=pending 且 expire_at < now`（列非空守卫：expire_at
    不可空，schema 层保证；SQL 下推不退化为全表 load）。
  - 与落账 worker 同秒竞态由双方 CAS 天然裁决：任一先落（mark_paid / expire），
  另一方 num_rows=0 被状态守卫拒绝，记 warning 跳过即可（预期竞态）。

  D-A6 纪律：状态转换只走领域 action（强一致路径 + 同事务联动），不裸写
  Ecto UPDATE。Order 多租户 `global?(true)`，跨租户读无需逐 tenant 迭代。

  ## 孤儿占位（011：无订单的 payment_pending 永久占座）

  开 / 邀请制策略收费报名一创建即落 `payment_pending` 并占用名额（ADR-0007），
  限时释放此前**只挂在订单上**——如果报名从未产生订单（微信押金场中途退出
  确认页、抖音/旧小红书端内无支付、web 端同类中途放弃），名额永远不会释放。

  占位时刻口径 = `COALESCE(approved_at, inserted_at)`：open/invite_only 策略
  创建时直接落 payment_pending，占位时刻 = `inserted_at`；request 策略先
  pending，审批通过落 payment_pending，占位时刻 = `approved_at`（两者只会有
  一个非空，见 `Enrollment.auto_confirm_status/1` 与 `prepare_confirm/1`）。
  超窗口口径与订单窗口同值（`Order.order_window_seconds/0`，单源），以后改
  支付窗口只改那一处即可，本处自动跟随。

  释放端口复用订单过期同款 `Enrollment.release_for_payment_expiry/1`（不新增
  释放路径）；候选先 `lock_for_order/1`（`FOR UPDATE`，与下单路径同一把锁）
  锁定再复核有无活跃订单，理由见 `sweep_orphan_holds/1` 内注释。

  本版**静默释放，不发通知**：`notify_expired/1` 依赖订单数据构建通知内容，
  孤儿场景无订单；且 tt/xhs 端内本就无小程序通知通道。用户在「我的报名」
  可见状态已变为 expired。若后续需要提醒，另立项复用 `payment_expired`
  模板，需要能在无订单时构建 data。
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

    results =
      Enum.map(@expiry_specs, fn spec ->
        {spec.resource, sweep(spec, now)}
      end)

    {orphan_count, orphan_failed?} = sweep_orphan_holds(now)

    expired =
      Enum.map(results, fn {resource, {count, _failed?}} -> {resource, count} end)

    summary_parts =
      Enum.map(expired, fn {resource, count} -> "#{count} #{kind(resource)}(s)" end) ++
        ["#{orphan_count} orphan hold(s)"]

    if Enum.any?(expired, fn {_resource, count} -> count > 0 end) or orphan_count > 0 do
      Logger.info("payment expiry sweep: #{Enum.join(summary_parts, ", ")} expired")
    end

    # 015 审计修复：DB 类硬失败不再折叠为 :skip——毒记录此前会每分钟静默重试
    # 到永远（占位永不释放，只升级到 1h 后的对账规④）。整拍上抛走 Oban 重试
    # （max_attempts 3）；重试幂等——已过期成功的单下拍不再命中过滤器，
    # 状态守卫类预期竞态照旧 :skip 不阻塞。
    if Enum.any?(results, fn {_resource, {_count, failed?}} -> failed? end) or orphan_failed? do
      {:error, :expire_hard_failure}
    else
      :ok
    end
  end

  @orphan_hold_candidate_sql """
  SELECT e.id FROM enrollments e
  WHERE e.status = 'payment_pending'
    AND COALESCE(e.approved_at, e.inserted_at) < $1
    AND NOT EXISTS (
      SELECT 1 FROM payments_orders o
      WHERE o.enrollment_id = e.id
        AND o.status IN ('pending','paid','refunding','refund_failed'))
  LIMIT 500
  """

  @active_order_statuses ~w(pending paid refunding refund_failed)

  # 无订单的 payment_pending 报名占位超窗释放（011）。LIMIT 500 防首拍存量
  # 过大一次拖长事务，剩余下一拍（每分钟）继续处理。
  defp sweep_orphan_holds(now) do
    cutoff = DateTime.add(now, -Order.order_window_seconds())

    case Cgc2046.Repo.query(@orphan_hold_candidate_sql, [cutoff]) do
      {:ok, %{rows: rows}} ->
        Enum.reduce(rows, {0, false}, fn [id], {acc, failed?} ->
          case release_orphan_hold(Ecto.UUID.load!(id)) do
            :released ->
              {acc + 1, failed?}

            :skip ->
              {acc, failed?}

            {:error, reason} ->
              Logger.error(
                "payment expiry: orphan hold #{Ecto.UUID.load!(id)} release hard failure: #{inspect(reason)}"
              )

              :telemetry.execute(
                [:cgc2046, :payment_expiry, :expire_failed],
                %{count: 1},
                %{resource: "orphan_hold"}
              )

              {acc, true}
          end
        end)

      {:error, reason} ->
        Logger.error(
          "payment expiry: orphan hold candidate scan hard failure: #{inspect(reason)}"
        )

        :telemetry.execute(
          [:cgc2046, :payment_expiry, :expire_failed],
          %{count: 1},
          %{resource: "orphan_hold"}
        )

        {0, true}
    end
  end

  # 先锁再复核再释放：READ COMMITTED 下，单条 `UPDATE ... WHERE NOT
  # EXISTS(orders)` 在等待下单事务的行锁后，子查询仍用语句开始时的快照，
  # 可能看不到刚提交的新订单 → 把刚下单的报名误释放。先 `FOR UPDATE`（与
  # 下单路径 lock_for_order/1 同一把锁）等到下单事务提交/回滚后，再发新
  # 语句查订单，才能看到已提交的订单，与下单路径的并发裁决口径一致。
  defp release_orphan_hold(id) do
    Cgc2046.Repo.transaction(fn ->
      with {:ok, %{status: :payment_pending}} <- Enrollment.lock_for_order(id),
           false <- active_order?(id),
           :ok <- Enrollment.release_for_payment_expiry(id) do
        :released
      else
        {:ok, _other_status} -> :skip
        true -> :skip
        {:error, reason} -> Cgc2046.Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp active_order?(enrollment_id) do
    sql = """
    SELECT EXISTS(
      SELECT 1 FROM payments_orders
      WHERE enrollment_id = $1 AND status = ANY($2)
    )
    """

    case Cgc2046.Repo.query(sql, [Cgc2046.Repo.uuid!(enrollment_id), @active_order_statuses]) do
      {:ok, %{rows: [[exists?]]}} -> exists?
      {:error, reason} -> Cgc2046.Repo.rollback(reason)
    end
  end

  # 列实体：SQL 下推过滤（status + 列非空 + 列 < now），不退化为全表 load。
  # 返回 {过期数, 是否存在硬失败}。
  defp sweep(%{resource: resource, status: status, deadline: {:column, column}}, now) do
    resource
    |> Ash.Query.filter(status == ^status and not is_nil(^ref(column)) and ^ref(column) < ^now)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce({0, false}, fn record, {acc, failed?} ->
      case expire_record(record) do
        :ok ->
          {acc + 1, failed?}

        :skip ->
          {acc, failed?}

        {:error, reason} ->
          Logger.error(
            "payment expiry: #{kind(resource)} #{record.id} expire hard failure: #{inspect(reason)}"
          )

          :telemetry.execute(
            [:cgc2046, :payment_expiry, :expire_failed],
            %{count: 1},
            %{resource: kind(resource)}
          )

          {acc, true}
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
  #
  # 015 审计修复：错误二分类——状态守卫类（并发终态变化先落库，Ash Invalid /
  # Stale 家族）= 预期竞态，warning + :skip；其余（DB 瞬断等）= 硬失败，
  # {:error, reason} 沿 sweep 上抛触发整拍重试。
  defp handle_expire_result(result, kind, id) do
    case result do
      {:ok, _} ->
        :ok

      {:error, error} ->
        if expected_race?(error) do
          Logger.warning(
            "payment expiry: #{kind} #{id} expire skipped (state guard): #{inspect(error)}"
          )

          :skip
        else
          {:error, error}
        end
    end
  end

  # 预期竞态的精确形状：Order :expire 的 CAS（claim/4）未命中 → BusinessError
  # code "order_already_processed"（order.ex domain_error_code 显式子句）。
  # DB 类失败走同族 BusinessError 但 code = "database_error"——那是硬失败，
  # 绝不能误判为竞态（015 审计修复的分类依据）。
  defp expected_race?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn
      %Cgc2046.Errors.BusinessError{code: "order_already_processed"} -> true
      _ -> false
    end)
  end

  defp expected_race?(_), do: false

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
