defmodule Cgc2046.Workers.CurriculumProgressWorker do
  @moduledoc """
  教研 run 完成判定扫描(切片 H U5, #180;Q7 discharge,KTD5;ADR-0009 PR③ 自 ResearchProgressWorker 改名)。

  Oban cron 每 5 分钟一拍(与 LearningProgressWorker 同节奏,`config.exs`),
  扫 `type=curriculum` 且非终态(pending/running/waiting)的 run:

  - run 锚定课程的 Curriculum.Output(kind=:issues)已存在 → 调既有
    `:complete` action 置 `succeeded`(内容提交即完成——`save_course_content`
    落库是唯一产出确认信号);
  - 无内容不动(waiting 教研产出);
  - 已终态不动(查询限定非终态,幂等)。

  key 解析:run `input_snapshot["key"]` 形如 `course_<id>`(curriculum instantiator 写入约定;event 型 key 不消费——Event 的教研产出后置)。

  单记录处理失败记 warning 不中断整拍(状态守卫幂等,并发终态变化属预期
  竞态);整拍幂等(完成看内容存在性)。
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    # 唯一窗与 cron 周期(5 分钟)对齐:防抖重复入队/手动重触造成的并发拍
    # (LearningProgressWorker 同款)。
    unique: [period: 300, states: :incomplete]

  require Ash.Query
  require Logger

  alias Cgc2046.Curriculum.Output
  alias Cgc2046.Workflows.WorkflowRun

  @non_terminal_statuses [:pending, :running, :waiting]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    completed = complete_finished_runs()

    if completed > 0 do
      Logger.info("curriculum progress sweep: #{completed} run(s) completed")
    end

    :ok
  end

  defp complete_finished_runs do
    curriculum_active_runs()
    |> Enum.reduce(0, fn run, acc ->
      case maybe_complete(run) do
        :completed -> acc + 1
        :skipped -> acc
      end
    end)
  end

  # 判定 = 课程内容存在(input key course_<id> → Curriculum.Output 同 key)
  defp maybe_complete(%WorkflowRun{} = run) do
    with course_id when is_binary(course_id) <- course_id_of(run),
         {:ok, _output} <- fetch_content(run.workspace_id, course_id) do
      complete_run(run)
    else
      _ -> :skipped
    end
  end

  defp complete_run(run) do
    case run
         |> Ash.Changeset.for_update(:complete, %{},
           tenant: run.workspace_id,
           authorize?: false
         )
         |> Ash.update(tenant: run.workspace_id, authorize?: false) do
      {:ok, _} ->
        :completed

      {:error, reason} ->
        Logger.warning(
          "CurriculumProgressWorker complete failed for run #{run.id}: #{inspect(reason)}"
        )

        :skipped
    end
  end

  # instance key 存于 input_snapshot["key"](curriculum instantiator 写入约定);
  # 前缀 course_ 之外的 key(event_)不消费
  defp course_id_of(%WorkflowRun{input_snapshot: snapshot}) when is_map(snapshot) do
    case Map.get(snapshot, "key") do
      "course_" <> course_id when byte_size(course_id) > 0 -> course_id
      _ -> nil
    end
  end

  defp course_id_of(_run), do: nil

  defp fetch_content(workspace_id, course_id) do
    Output
    |> Ash.Query.filter(key == ^Output.course_key(course_id) and kind == :issues)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: workspace_id)
    |> case do
      {:ok, nil} -> {:error, :no_content}
      {:ok, output} -> {:ok, output}
      {:error, _} -> {:error, :content_read_failed}
    end
  end

  # 非终态且定义 type=curriculum 的 run(curriculum reaper 的查询过滤同款;
  # WorkflowRun multitenancy global?(true):无 tenant 全局读)
  defp curriculum_active_runs do
    WorkflowRun
    |> Ash.Query.filter(definition.type == :curriculum and status in ^@non_terminal_statuses)
    |> Ash.read!(authorize?: false)
  end
end
