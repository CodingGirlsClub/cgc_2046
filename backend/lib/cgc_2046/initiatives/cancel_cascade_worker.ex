defmodule Cgc2046.Initiatives.CancelCascadeWorker do
  @moduledoc """
  Initiative 中止级联（#628）：`Initiative :cancel` 事务内入队的 outbox job，
  把该活动下**仍 `open`** 的挂载场逐场 `Event :cancel`。

  为什么是「逐场 cancel 而不是批量退款」：退款与通知的既有链路是
  `event.ended` 信号 → `Cgc2046.Admission.Workers.OfferingCancelRefundWorker`
  （cancelled → paid 逐笔全额退 / payment_pending 撤销并释放名额；closed →
  明确不退，见该模块 :62-77 的分叉）。本 worker 只做「把活动级中止翻译成场次级
  中止」，退款的判定与执行**零新增代码**——中止 = 无条件全额退这条口径因此与
  Event/Course 逐字同源，不存在第二套批量走查。

  范围（issue #628 裁决 D4）：只碰 `status = open` 的挂载场——
  `draft` 场无报名无资金、且不能经 Event `:cancel`（其 CAS 只吃 open）；
  `closed` / `cancelled` 是历史事实，不回溯改写（已收官场的 paid 押金单继续由
  `DepositForfeitWorker` 按 no-show 结算，中止不改写已结算事实）。

  幂等：逐场转换走 Event `:cancel` 的状态 CAS（open → cancelled，`StatusTransition`），
  重复执行/信号重投时 `num_rows=0` 被拒、记 warning 跳过；审计行只在有实际动作
  （计数非全零）时落一行，重投不产生 0/0 噪音行（范式同
  `OfferingCancelRefundWorker.refund_offering_enrollments/3` :79-90）。

  `:close`（收尾）**不**入队本 worker（D2：收尾不级联、不退款）。
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 5,
    unique: [period: 300, states: :incomplete]

  require Ash.Query
  require Logger

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.Events.Event
  alias Cgc2046.Initiatives.Initiative

  # 分批步长：控制单波对 signals/退款链的瞬时入队量（同 OfferingCancelRefundWorker）
  @batch_size 50

  @doc """
  `Initiative :cancel` 的 after_action 调用：与状态终态**同事务**入队
  （`Oban.insert!` 失败 raise → 整个 cancel 回滚，可安全重试；outbox 语义同
  `Workflows.SignalEmitter` 的 "job 与实体终态同事务提交"）。
  """
  @spec enqueue(String.t()) :: :ok
  def enqueue(initiative_id) when is_binary(initiative_id) do
    %{"initiative_id" => initiative_id}
    |> new()
    |> Oban.insert!()

    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"initiative_id" => initiative_id}}) do
    # 回查活动状态后分派：cancelled → 级联；closed → 明确不级联（收尾口径）；
    # 未定态 → 不认领、返回错误等 Oban 重试（终态可见性竞态窗口，同
    # OfferingCancelRefundWorker.resolve_and_refund/3 :60-77 的分派纪律）。
    case Ash.get(Initiative, initiative_id, authorize?: false) do
      {:ok, %{status: :cancelled}} ->
        cascade(initiative_id)

      {:ok, %{status: :closed}} ->
        :ok

      {:ok, %{status: status}} ->
        {:error, {:initiative_status_not_settled, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cascade(initiative_id) do
    counts = stream_open_events(initiative_id) |> Enum.reduce(empty_counts(), &cancel_event/2)

    unless counts == empty_counts() do
      log_batch_audit(initiative_id, counts)
    end

    :ok
  end

  defp empty_counts, do: %{cancelled: 0, skipped: 0}

  # keyset 游标分批（`id > cursor` + limit）：大活动下内存峰值与首响延迟受控
  # （范式同 OfferingCancelRefundWorker.stream_offering_enrollments/1 :98-119）。
  defp stream_open_events(initiative_id) do
    Stream.unfold("", fn cursor ->
      query =
        Event
        |> Ash.Query.filter(initiative_id == ^initiative_id and status == :open)
        |> Ash.Query.sort(id: :asc)
        |> Ash.Query.limit(@batch_size)

      query = if cursor == "", do: query, else: Ash.Query.filter(query, id > ^cursor)
      batch = Ash.read!(query, authorize?: false)

      case batch do
        [] -> nil
        rows -> {rows, List.last(rows).id}
      end
    end)
    |> Stream.flat_map(& &1)
  end

  # 逐笔隔离：单场失败只记 warning 不阻塞其余（部分失败由重投/人工单场 cancel 收敛）。
  defp cancel_event(event, counts) do
    case event
         |> Ash.Changeset.for_update(:cancel, %{}, tenant: event.workspace_id)
         |> Ash.update(tenant: event.workspace_id, authorize?: false) do
      {:ok, _} ->
        Map.update!(counts, :cancelled, &(&1 + 1))

      {:error, reason} ->
        Logger.warning("initiative cancel cascade: event #{event.id} skipped: #{inspect(reason)}")

        Map.update!(counts, :skipped, &(&1 + 1))
    end
  end

  # 系统驱动无 actor（actor_id = nil 与 CLI 系统动作同语义）；每 initiative 一行，
  # metadata 带计数（口径同 :event_cancel_batch_refund）。
  defp log_batch_audit(initiative_id, counts) do
    case AdminActionLog.log(%{
           actor_id: nil,
           action: :initiative_cancel_batch,
           target_type: :initiative,
           target_id: initiative_id,
           metadata: %{
             "cancelled_events" => counts.cancelled,
             "skipped" => counts.skipped
           }
         }) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "initiative cancel cascade: audit log failed for #{initiative_id}: #{inspect(reason)}"
        )
    end
  end
end
