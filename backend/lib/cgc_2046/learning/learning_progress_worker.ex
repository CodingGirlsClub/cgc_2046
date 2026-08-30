defmodule Cgc2046.Learning.LearningProgressWorker do
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

  2. **停滞升级（D6-③）**：`running` 且 facts 无新增 > 7 天（S8 起 = 最新 attempt created_at，零 attempt 回退 run inserted_at——
     running 态下 facts 写入是唯一更新路径）→ 经 NotificationWorker 入队提醒
     报名学员（48h 提醒同款 Oban 入队模式；7 天 args-unique 保证同一 run 同一
     收件人 7 天内至多一条）。收件人守卫：反查 Enrollment 仍 `confirmed` 才提醒。
     不自动 cancel——停滞是可见性事件，干预由人/学员侧决定。

  对账接口（E-10 #125 规则编号体系；本 worker 不消费 Finding，只对齐语义）：
  - 规则①：confirmed enrollment 无 learning run（本 worker 不消费；由
    LearningInstantiator 的 warning 日志 + 报名/run 两表可扫支撑，E-10
    ReconciliationScanWorker 落地）。
  - 规则⑦：`learning_run_stalled`（E-9 #122 补差）——停滞判定与本 worker 提醒
    同一口径，阈值同源
    `Cgc2046.Learning.Runs.stagnant_cutoff/1`（本 worker 与对账扫描只引用，不各自
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
  alias Cgc2046.Workflows.WorkflowRun

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

  @doc "停滞阈值 cutoff（7 天，D6-③）；同源 `Runs.stagnant_cutoff/1`（对账规则⑦复用同一语义）。"
  def stagnant_cutoff(now \\ DateTime.utc_now()) do
    Cgc2046.Learning.Runs.stagnant_cutoff(now)
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

  # S8（ADR-0011）：完成判定 = Runs.complete_when_mastered/1 单源——
  # 必修 objective 全 ever_mastered 即 complete（issue/checklist 口径随
  # LearningRecord 退役）。:incomplete/:not_running → skipped；失败记日志。
  defp maybe_complete(%WorkflowRun{} = run) do
    case Cgc2046.Learning.Runs.complete_when_mastered(run) do
      {:ok, :completed, _run} ->
        :completed

      {:ok, _outcome, _run} ->
        :skipped

      {:error, reason} ->
        Logger.warning(
          "LearningProgressWorker complete failed for run #{run.id}: #{inspect(reason)}"
        )

        :skipped
    end
  end

  # --- 停滞升级（D6-③） -------------------------------------------------------

  # S8（R50）：停滞口径 = Runs.stagnant?/2 单源——活动时间 = 最新 attempt
  # created_at，零 attempt 回退 run inserted_at（updated_at 不再代理活跃）。
  defp remind_stagnant_runs(now) do
    learning_running_runs()
    |> Enum.filter(&Cgc2046.Learning.Runs.stagnant?(&1, now))
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
    identities = Cgc2046.Notifications.Fanout.identities(enrollment.user_id)

    if identities == [] do
      # 无平台身份 → 无可入队（:no_identity 分类语义留在本 worker，PR-C）
      :skipped
    else
      Cgc2046.Notifications.Fanout.deliver(
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
