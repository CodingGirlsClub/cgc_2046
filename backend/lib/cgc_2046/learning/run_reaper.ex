defmodule Cgc2046.Learning.RunReaper do
  @moduledoc """
  学习 run 回收（offering 取消级联；与 `Cgc2046.Curriculum.Reaper` 对教研 run
  的回收对等）。

  订阅 `event.ended` / `course.ended` → **回查实体 status 仅 `cancelled`** 停该
  offering 下非终态学习 run（WorkflowRun `:cancel`——含 checkpoint 清理与
  finished_at）。`closed` = 正常结束（D4），学员可继续学习已有内容，不动——
  cancelled/closed 分派与 `OfferingCancelRefundWorker` 一致。订阅骨架与
  claim-after 幂等语义由 `Cgc2046.Workflows.SignalSubscriber` 统一持有。

  - **只碰学习 run**：按 `definition.type == :learning` 过滤（教研 run 由
    Curriculum.Reaper 回收，互不越界）。
  - **关联路径**：run → `subject_enrollment_id` → Enrollment.event_id/course_id
    （学习 run 的 instance key 含 revision 后缀，不按 key 反查）。
  - **竞态兜底**：cancel 与报名 confirm 的残余窗口由本回收 + E-10 对账规则⑦
    （learning run 停滞）共同收敛。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["event.ended", "course.ended"],
    idempotency: :claim_after_effects,
    consumer_key: "learning_run_reaper"

  require Ash.Query
  require Logger

  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Courses.Course
  alias Cgc2046.Events.Event
  alias Cgc2046.Workflows.WorkflowRun

  @non_terminal_statuses [:pending, :running, :waiting]

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(_type, %{"event_id" => event_id}) when is_binary(event_id),
    do: reap(Event, :event, event_id)

  def handle(_type, %{"course_id" => course_id}) when is_binary(course_id),
    do: reap(Course, :course, course_id)

  def handle(_type, data) do
    Logger.warning("Learning.RunReaper received signal without entity id: #{inspect(data)}")
    :ok
  end

  # 回查实体状态后分派（同 OfferingCancelRefundWorker 的 resolve 模式）：
  # cancelled → 停学习 run；closed → 明确不动；未定态 → 不认领等信号重投
  # （ended 信号先于终态可见的竞态窗口）。
  defp reap(module, kind, id) do
    case Ash.get(module, id, authorize?: false) do
      {:ok, %{status: :cancelled}} ->
        stop_runs(kind, id)

      {:ok, %{status: :closed}} ->
        :ok

      {:ok, _other_status} ->
        {:error, {:offering_status_not_settled, kind}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Enrollment 是 global?(true) 租户资源，PK 全局唯一，可不带 tenant 读
  # （同 OfferingCancelRefundWorker.enrollment_scope/2）。
  defp enrollment_ids(:event, id),
    do: Enrollment |> Ash.Query.filter(event_id == ^id) |> read_ids!()

  defp enrollment_ids(:course, id),
    do: Enrollment |> Ash.Query.filter(course_id == ^id) |> read_ids!()

  defp read_ids!(query), do: query |> Ash.read!(authorize?: false) |> Enum.map(& &1.id)

  # WorkflowRun multitenancy global?(true)：无 tenant 全局读（同 Curriculum.Reaper）。
  # 返回 :ok（全部成功或无可回收 run）| {:error, failed_count}（骨架不落 claim 等重投）。
  defp stop_runs(kind, id) do
    case enrollment_ids(kind, id) do
      [] ->
        :ok

      enrollment_ids ->
        WorkflowRun
        |> Ash.Query.filter(
          definition.type == :learning and status in @non_terminal_statuses and
            subject_enrollment_id in ^enrollment_ids
        )
        |> Ash.read!(authorize?: false)
        |> Enum.reduce(:ok, fn run, acc ->
          case cancel_run(run) do
            :ok -> acc
            :error -> {:error, if(acc == :ok, do: 1, else: elem(acc, 1) + 1)}
          end
        end)
    end
  end

  defp cancel_run(run) do
    case run
         |> Ash.Changeset.for_update(:cancel, %{}, tenant: run.workspace_id, authorize?: false)
         |> Ash.update(tenant: run.workspace_id, authorize?: false) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Learning.RunReaper cancel failed for run #{run.id}: #{inspect(reason)}")
        :error
    end
  end
end
