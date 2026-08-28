defmodule Cgc2046.Workers.LearningProgressWorker do
  @moduledoc """
  学习 workflow 进度扫描（E-7 #122;完成判定升级:切片 H U4, #180）。

  Oban cron 每 5 分钟一拍（`config.exs` crontab；ApprovalExpiryWorker 同款模式），
  扫 `type=learning` 且 `status=running` 的 run，做两件事：

  1. **完成判定（U4,全 issue Done）**：run 锚定 enrollment 对应课程的
     course content（Curriculum.Output kind=:issues）+ 该 user 学习记录，
     全部 issue 的 checklist 条目均有 done 记录 → 调既有 `:complete` action
     置 `succeeded`（完成语义从「走完了」升级为「学会了」，#180 US25）。
     无内容课程（无 Curriculum.Output）不判完成（skip，不报错）；run 终态
     不重扫（查询限定 running）。

  2. **停滞升级（D6-③）**：`running` 且 facts 无新增 > 7 天（`updated_at` 代理——
     running 态下 facts 写入是唯一更新路径）→ 经 NotificationWorker 入队提醒
     报名学员（48h 提醒同款 Oban 入队模式；7 天 args-unique 保证同一 run 同一
     收件人 7 天内至多一条）。收件人守卫：反查 Enrollment 仍 `confirmed` 才提醒。
     不自动 cancel——停滞是可见性事件，干预由人/学员侧决定。

  对账接口（E-10 #125 规则编号体系；本 worker 不消费 Finding，只对齐语义）：
  - 规则①：confirmed enrollment 无 learning run（本 worker 不消费；由
    LearningInstantiator 的 warning 日志 + 报名/run 两表可扫支撑，E-10
    ReconciliationScanWorker 落地）。
  - 规则⑦：`learning_run_stalled`（E-9 #122 补差）——停滞判定与本 worker 提醒
    同一口径（`updated_at` 严格早于 cutoff），阈值同源
    `LearningProgress.stagnant_cutoff/1`（本 worker 与对账扫描只引用，不各自
    定义）；分工：本 worker 负责提醒学员，ReconciliationScanWorker 负责对账
    可见（/admin 对账页 findings 列表）。

  单记录处理失败记 warning 不中断整拍（领域 action 状态守卫幂等，并发终态变化
  属预期竞态）；整拍本身幂等（完成判定看记录存在性，提醒靠 args-unique 去重）。
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    # 唯一窗与 cron 周期（5 分钟）对齐：防抖重复入队/手动重触造成的并发拍
    # （ApprovalExpiryWorker 同款）。
    unique: [period: 300, states: :incomplete]

  require Ash.Query
  require Logger

  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Workflows.{LearningProgress, WorkflowRun}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    completed = complete_finished_runs()
    reminded = remind_stagnant_runs(DateTime.utc_now())

    if completed + reminded > 0 do
      Logger.info(
        "learning progress sweep: #{completed} run(s) completed, " <>
          "#{reminded} stagnation reminder(s) enqueued"
      )
    end

    :ok
  end

  @doc "停滞阈值 cutoff（7 天，D6-③）；同源 `LearningProgress.stagnant_cutoff/1`（对账规则⑦复用同一语义）。"
  def stagnant_cutoff(now \\ DateTime.utc_now()) do
    LearningProgress.stagnant_cutoff(now)
  end

  # --- 完成判定（D6-②） -------------------------------------------------------

  defp complete_finished_runs do
    learning_running_runs()
    |> Enum.reduce(0, fn run, acc ->
      case maybe_complete(run) do
        :completed -> acc + 1
        :skipped -> acc
      end
    end)
  end

  # U4(#180):完成条件 = 全部 issue Done(数据源 = course content
  # Curriculum.Output + 该 user 学习记录;无内容课程不判完成,KTD3)。
  defp maybe_complete(%WorkflowRun{} = run) do
    with enrollment when is_map(enrollment) <- fetch_enrollment_or_nil(run),
         {:ok, content} <- fetch_course_content(run.workspace_id, enrollment),
         {:ok, records} <- fetch_records(run.workspace_id, enrollment),
         true <- LearningProgress.all_issues_done?(content, records) do
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
          "LearningProgressWorker complete failed for run #{run.id}: #{inspect(reason)}"
        )

        :skipped
    end
  end

  # course_id 缺失的 run(事件型 enrollment)无课程内容可判——skip。
  # 读取委托 Enrollment.anchor/1（锚定单源，架构深化 E），错误坍缩 nil。
  defp fetch_enrollment_or_nil(%WorkflowRun{} = run) do
    case Enrollment.anchor(run.input_snapshot) do
      {:ok, enrollment} -> enrollment
      {:error, _} -> nil
    end
  end

  # 无内容课程(无 Curriculum.Output)→ {:ok, nil} → all_issues_done? false(skip)
  defp fetch_course_content(workspace_id, %{course_id: course_id})
       when is_binary(course_id) do
    Cgc2046.Curriculum.Output
    |> Ash.Query.filter(
      key == ^Cgc2046.Curriculum.Output.course_key(course_id) and kind == :issues
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: workspace_id)
    |> case do
      {:ok, nil} -> {:ok, nil}
      {:ok, output} -> {:ok, output.data}
      {:error, _} -> {:error, :content_read_failed}
    end
  end

  defp fetch_course_content(_workspace_id, _enrollment), do: {:ok, nil}

  defp fetch_records(workspace_id, %{course_id: course_id, user_id: user_id})
       when is_binary(course_id) and is_binary(user_id) do
    Cgc2046.Learning.LearningRecord
    |> Ash.Query.filter(course_id == ^course_id and user_id == ^user_id)
    |> Ash.read(authorize?: false, tenant: workspace_id)
  end

  defp fetch_records(_workspace_id, _enrollment), do: {:ok, []}

  # --- 停滞升级（D6-③） -------------------------------------------------------

  defp remind_stagnant_runs(now) do
    cutoff = stagnant_cutoff(now)

    learning_running_runs()
    |> Enum.filter(fn run ->
      run.updated_at && DateTime.compare(run.updated_at, cutoff) == :lt
    end)
    |> Enum.reduce(0, fn run, acc ->
      case remind_stagnant(run) do
        :reminded -> acc + 1
        :skipped -> acc
      end
    end)
  end

  defp remind_stagnant(%WorkflowRun{} = run) do
    with {:ok, %Enrollment{status: :confirmed} = enrollment} <-
           Enrollment.anchor(run.input_snapshot) do
      remind_stagnant_for(run, enrollment)
    else
      _ -> :skipped
    end
  end

  # 基线吞错语义（迁移前 NS.enqueue_learning_stagnation_jobs 的 rescue 分支原样
  # 收敛于此，评审 MED-1）：identities 读取或入队抛错 → Logger.warning + 该记录
  # 按 :reminded 计（基线 rescue 返回 :ok → LPW 映射 :reminded），单记录失败
  # 不中断整拍（moduledoc 不变量）。
  defp remind_stagnant_for(run, enrollment) do
    identities = Cgc2046.NotificationFanout.identities(enrollment.user_id)

    if identities == [] do
      # 无平台身份 → 无可入队（:no_identity 分类语义留在本 worker，PR-C）
      :skipped
    else
      Cgc2046.NotificationFanout.deliver(
        {enrollment.user_id, identities},
        "learning_stagnation",
        %{
          "enrollment_id" => run.input_snapshot["enrollment_id"],
          "run_id" => run.id,
          "title" => run.input_snapshot["title"]
        },
        %{"run_id" => run.id}
      )

      :reminded
    end
  rescue
    error ->
      Logger.warning("learning stagnation reminder enqueue failed: #{Exception.message(error)}")
      :reminded
  end

  # --- 共用查询 ----------------------------------------------------------------

  # running 且定义 type=learning 的 run（definition 关系过滤 + 预载 node_def，
  # 完成判定与停滞扫描共用一拍查询）。
  defp learning_running_runs do
    WorkflowRun
    |> Ash.Query.filter(status == :running and definition.type == :learning)
    |> Ash.Query.load(definition: [:node_def])
    |> Ash.read!(authorize?: false)
  end
end
