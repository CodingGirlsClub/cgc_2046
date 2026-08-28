defmodule Cgc2046.Curriculum.Reaper do
  @moduledoc """
  教研 run 回收（E-9 #124，总纲:171「event.ended → stop 回收」;ADR-0009 PR③ 自
  Workflows.ResearchRunReaper 迁入改名）。

  订阅 `event.ended` / `course.ended` → 停该实体的非终态教研 run
  （WorkflowRun :cancel——含 checkpoint 清理与 finished_at）。
  订阅骨架与 claim-after 幂等语义由 `Cgc2046.Workflows.SignalSubscriber`
  统一持有（语义事实见其 moduledoc）。

  - **非教研不碰**：按 `definition.type == :curriculum` 过滤（BLOCKING 5）。
  - **竞态兜底**：Curriculum.Instantiator 建 run 前二次校验实体 open（BLOCKING 3）；
    残余窗口由对账扫描 E-10 规则⑤登记（#125）。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["event.ended", "course.ended"],
    idempotency: :claim_after_effects,
    consumer_key: "reaper"

  require Ash.Query
  require Logger

  alias Cgc2046.Workflows.WorkflowRun

  @non_terminal_statuses [:pending, :running, :waiting]

  # 信号 → 按 entity instance key（"event_#{id}" / "course_#{id}"）停教研 run。
  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(_type, %{"event_id" => event_id}) when is_binary(event_id),
    do: stop_runs("event_#{event_id}")

  def handle(_type, %{"course_id" => course_id}) when is_binary(course_id),
    do: stop_runs("course_#{course_id}")

  def handle(_type, data) do
    Logger.warning("Curriculum.Reaper received signal without entity id: #{inspect(data)}")
    :ok
  end

  # instance key 存于 input_snapshot["key"]（curriculum instantiator 写入约定）。
  # WorkflowRun multitenancy global?(true)：无 tenant 全局读（同 expiry worker）。
  # 限定 definition.type == :curriculum（BLOCKING 5：不碰同 key 的其他类型 run）。
  # 返回 :ok（全部成功或无可回收 run）| {:error, failed_count}（骨架不落 claim 等重投）。
  defp stop_runs(key) do
    WorkflowRun
    |> Ash.Query.filter(
      definition.type == :curriculum and status in @non_terminal_statuses and
        input_snapshot["key"] == ^key
    )
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(:ok, fn run, acc ->
      case cancel_run(run) do
        :ok -> acc
        :error -> {:error, if(acc == :ok, do: 1, else: elem(acc, 1) + 1)}
      end
    end)
  end

  defp cancel_run(run) do
    case run
         |> Ash.Changeset.for_update(:cancel, %{}, tenant: run.workspace_id, authorize?: false)
         |> Ash.update(tenant: run.workspace_id, authorize?: false) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Curriculum.Reaper cancel failed for run #{run.id}: #{inspect(reason)}")
        :error
    end
  end
end
