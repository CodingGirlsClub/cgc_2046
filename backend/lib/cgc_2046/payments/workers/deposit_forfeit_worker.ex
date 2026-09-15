defmodule Cgc2046.Payments.Workers.DepositForfeitWorker do
  @moduledoc """
  押金 no-show 结算 worker（U8/KTD7、KTD8、KTD11；R8、R9）。

  Oban cron 每 10 分钟一拍（config.exs crontab 第 5 项以后的末位），把「活动已
  正常结束满 48h、押金单仍 `paid`、且无 Attendance」的报名逐笔结算为
  `forfeited`（押金不退、留作平台收入，KD4/AE7）。

  归属（KTD11/ADR-0010 判据）：本 worker 只推进 Order 终态并记审计、不编排
  Enrollment，故落 Payments 域；核销（推进报名维度的到场事实）反向落 Admission。

  ## 判定与写序（KTD7/KTD8）

  1. **SQL 下推候选**：`order_kind = deposit ∧ status = paid` ∧ 关联 Event
     `status = closed ∧ ends_at 非空 ∧ ends_at + 48h 已过` ∧ 无 Attendance 行
     ——过滤全部落在 SQL 上，不退化为全表 load（`payment_expiry_worker` 同款；
     `attendances` 的存在性判定同处下推，避免逐单 N+1）；
  2. **逐笔加锁**：`Enrollment.lock_for_order/1`（与下单/落账/核销共用同一条
     报名行锁，KTD6 锁序）→ **锁内重查 Attendance**（候选查询与拿锁之间的
     核销窗口不留误没收）→ `Order :forfeit` CAS（`paid → forfeited`）；
  3. `num_rows = 0` = 已被他路接管（自助取消、批量退、核销即退、并发重投），
     幂等 no-op（KTD8 单一仲裁点：不建优先级分派器）；
  4. 有增量的 event 聚合成一行 `AdminActionLog :deposit_forfeit`
     （actor_id = nil 系统语义，metadata 带笔数/金额/order id 列表；零增量不落
     行——重投与空拍不留 0 值噪音，`offering_cancel_refund_worker` 同款）；
  5. 单笔失败 warning 不中断整拍；DB 类硬失败记 error 并把整拍上抛走 Oban
     重试（max_attempts 3，`payment_expiry_worker` 的 015 二分类纪律）。

  ## 与核销同瞬间（跨表竞态的显式出路）

  两方先争同一条 Enrollment 行锁：核销先提交 → 本 sweep 锁内重查命中
  Attendance 行、跳过（订单留在核销即退链上）；本 sweep 先提交 → 核销的
  KTD6 分派表把 `forfeited` 单映射为 `deposit_already_forfeited` 业务错误，
  Attendance 不落库（不静默只记到场）。

  ## 锚点（KTD7）

  只认 `ends_at`（活动结束的权威事实）+ 48h。**禁用 `updated_at` 为锚**
  （本仓两次「越活跃越不告警」事故的教训：活跃场次的多次状态写入会持续刷新
  `updated_at`，结算时机被无限推迟；`ends_at` 不受活动期写入影响）。押金场
  开启要求 `ends_at` 非空（Event validation），从根上消除提前没收。

  仅 `closed` 场进入结算：`cancelled` 由 `OfferingCancelRefundWorker` 批量退
  接管，`open` 未到结算点——优先级矩阵由源态与 Event 状态机保证（KTD8）。

  ## 无锚场防御（不静默滞留）

  `closed` 且 `ends_at` 为空、名下仍有 paid 押金单的场（`ends_at` 必填校验
  落地前的存量 / 旁路数据，属防御面）不结算、也不静默：产出 Finding
  `:deposit_settlement_unanchored`（entity = event；刷新语义同对账扫描 D2——
  命中 upsert 保 first_seen_at / 未命中删除；首次发现补 Logger.warning 进
  ops 告警通道）。该 kind 由本 worker 产出，`ReconciliationScanWorker` 的
  规则表不重复扫描。

  ## 白名单（KTD11）

  新 worker 名同时进对账规 6 死信白名单（`ReconciliationScanWorker`）——本
  sweep 连续三拍硬失败即 discarded，虽由下一拍 cron 自愈，但死信窗口内必须
  在 /admin 对账页可见（资金终态滞留不静默）。
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    # 唯一窗与 cron 周期对齐（KTD7）：防抖重复入队/手动重触造成的并发双拍；
    # 拍内的 CAS 本身幂等，唯一任务是第二层。
    unique: [period: 300, states: :incomplete]

  require Logger

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Payments.Order
  alias Cgc2046.Reconciliation.Finding
  alias Cgc2046.Repo

  # no-show 结算锚点（KTD7）：ends_at + 48h
  @settle_after_seconds 48 * 60 * 60

  # 无锚场 Finding 的规则名（Finding @rule_values 同值；本 worker 单点产出）
  @rule :deposit_settlement_unanchored

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    sync_unanchored_findings()

    {forfeited, failures} = sweep()

    log_audit(forfeited)

    if forfeited != [] do
      Logger.info("deposit forfeit sweep: #{length(forfeited)} order(s) forfeited")
    end

    if failures == 0 do
      :ok
    else
      {:error, :forfeit_hard_failure}
    end
  end

  # ── no-show 结算扫描 ───────────────────────────────────────────────────────

  # 逐笔隔离：CAS 落败（他路先接管）静默跳过；硬失败记 error 后继续下一笔，
  # 整拍末尾统一上抛走 Oban 重试。返回 {本次成功没收的候选（正序）, 硬失败数}。
  defp sweep do
    candidates()
    |> Enum.reduce({[], 0}, fn candidate, {forfeited, failures} ->
      case settle(candidate) do
        :forfeited ->
          {[candidate | forfeited], failures}

        :skipped ->
          {forfeited, failures}

        {:error, reason} ->
          Logger.error(
            "deposit forfeit: order #{candidate.order_id} settle hard failure: #{inspect(reason)}"
          )

          {forfeited, failures + 1}
      end
    end)
    |> then(fn {forfeited, failures} -> {Enum.reverse(forfeited), failures} end)
  end

  # 候选 = SQL 下推：deposit ∧ paid ∧ event.closed ∧ ends_at 过点 ∧ 无 Attendance。
  # `NOW() AT TIME ZONE 'UTC'` 与 `ends_at`（无时区的 UTC 墙钟列）同域比较，
  # 不依赖会话 TimeZone 设置。
  defp candidates do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT o.id, o.enrollment_id, en.event_id, o.amount_cents
        FROM payments_orders o
        JOIN enrollments en ON en.id = o.enrollment_id
        JOIN events e ON e.id = en.event_id
        WHERE o.order_kind = 'deposit'
          AND o.status = 'paid'
          AND e.status = 'closed'
          AND e.ends_at IS NOT NULL
          AND e.ends_at < (NOW() AT TIME ZONE 'UTC') - ($1 * INTERVAL '1 second')
          AND NOT EXISTS (
            SELECT 1 FROM attendances a WHERE a.enrollment_id = o.enrollment_id
          )
        ORDER BY o.id
        """,
        [@settle_after_seconds]
      )

    Enum.map(rows, fn [order_id, enrollment_id, event_id, amount_cents] ->
      %{
        order_id: Ecto.UUID.load!(order_id),
        enrollment_id: Ecto.UUID.load!(enrollment_id),
        event_id: Ecto.UUID.load!(event_id),
        amount_cents: amount_cents
      }
    end)
  end

  # 单笔 = 一个事务：报名行锁存活至本事务提交（`lock_for_order/1` 契约），
  # 锁内重查 Attendance 与 forfeit CAS 因此在同一临界区内裁决。
  defp settle(candidate) do
    case Repo.transaction(fn -> locked_settle(candidate) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp locked_settle(candidate) do
    case Enrollment.lock_for_order(candidate.enrollment_id) do
      {:ok, _locked} ->
        case attendance_present?(candidate.enrollment_id) do
          # 核销即退已接管（锁前查询与拿锁之间落行）：不没收已到场者押金
          {:ok, true} -> :skipped
          {:ok, false} -> forfeit(candidate)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 到场事实谓词单源见 Attendance.checked_in?/1；本处把读取失败包装为
  # {:database, reason}（该 worker 的硬失败分类依赖此形状）。
  defp attendance_present?(enrollment_id) do
    case Cgc2046.Admission.Attendance.checked_in?(enrollment_id) do
      {:ok, present} -> {:ok, present}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  defp forfeit(candidate) do
    case Ash.get(Order, candidate.order_id, authorize?: false) do
      {:ok, order} ->
        order
        |> Ash.Changeset.for_update(:forfeit, %{})
        |> Ash.update(tenant: order.workspace_id, authorize?: false)
        |> classify()

      # 读取失败（含行被并发删除的理论面）不是「已结算」：按硬失败上报，下拍重试
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp classify({:ok, _forfeited}), do: :forfeited

  # 预期竞态的精确形状：`:forfeit` 的 CAS（claim/4）未命中 → BusinessError
  # code "order_already_processed"（order.ex 显式子句）。他路（自助取消 / 批量退 /
  # 核销即退 / 并发重投）先落即预期路径，跳过。其余（DB 瞬断等）是硬失败，
  # 绝不能折叠为 :skip——吞掉会把「到点未结算」的单永久滞留在 paid。
  defp classify({:error, %Ash.Error.Invalid{errors: errors}} = result) do
    if Enum.any?(errors, &match?(%BusinessError{code: "order_already_processed"}, &1)) do
      :skipped
    else
      {:error, result}
    end
  end

  defp classify({:error, reason}), do: {:error, reason}

  # ── 审计（批量口径：有增量的 event 一行）──────────────────────────────────

  defp log_audit([]), do: :ok

  defp log_audit(forfeited) do
    forfeited
    |> Enum.group_by(& &1.event_id)
    |> Enum.each(fn {event_id, rows} -> write_audit(event_id, rows) end)
  end

  defp write_audit(event_id, rows) do
    case AdminActionLog.log(%{
           actor_id: nil,
           action: :deposit_forfeit,
           target_type: :event,
           target_id: event_id,
           metadata: %{
             "forfeited_orders" => length(rows),
             "forfeited_cents" => Enum.sum(Enum.map(rows, & &1.amount_cents)),
             "order_ids" => Enum.map(rows, & &1.order_id)
           }
         }) do
      {:ok, _log} ->
        :ok

      # CAS 已提交，审计失败无法回滚没收事实（与 offering_cancel_refund_worker
      # 的批量审计同款权衡）：warning 落日志，没收本身不回退。
      {:error, reason} ->
        Logger.warning(
          "deposit forfeit: audit log failed for event #{event_id}: #{inspect(reason)}"
        )
    end
  end

  # ── 无锚场 Finding（刷新语义单源见 Finding.apply_rule/3，同对账扫描 D2）────

  defp sync_unanchored_findings do
    Finding.apply_rule(@rule, unanchored_candidates(),
      log_prefix: "deposit forfeit",
      on_create: fn _rule, candidate, result -> warn_new(candidate, result) end
    )
  end

  # closed ∧ ends_at 为空 ∧ 名下仍有 paid 押金单：结算锚点缺失、订单会静默滞留。
  # 按 event 聚合（Finding 唯一键 (rule, entity_type, entity_id) 的 entity 是场）。
  defp unanchored_candidates do
    {:ok, %{rows: rows}} =
      Repo.query("""
      SELECT en.event_id, e.workspace_id, COUNT(*)::bigint, COALESCE(SUM(o.amount_cents), 0)::bigint
      FROM payments_orders o
      JOIN enrollments en ON en.id = o.enrollment_id
      JOIN events e ON e.id = en.event_id
      WHERE o.order_kind = 'deposit'
        AND o.status = 'paid'
        AND e.status = 'closed'
        AND e.ends_at IS NULL
      GROUP BY en.event_id, e.workspace_id
      """)

    Enum.map(rows, fn [event_id, workspace_id, count, cents] ->
      %{
        entity_type: :event,
        entity_id: Ecto.UUID.load!(event_id),
        workspace_id: Ecto.UUID.load!(workspace_id),
        detail: %{
          reason: "closed_event_without_ends_at",
          paid_deposit_orders: count,
          paid_cents: cents
        }
      }
    end)
  end

  # 该场在有效数据下不可能存在（押金场必填 ends_at），出现即需人介入。
  defp warn_new(candidate, {:ok, _finding}) do
    Logger.warning(
      "deposit forfeit: closed event #{candidate.entity_id} has no ends_at — " <>
        "#{candidate.detail.paid_deposit_orders} paid deposit order(s) cannot be settled"
    )
  end

  defp warn_new(_candidate, _result), do: :ok
end
