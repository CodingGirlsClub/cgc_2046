defmodule Cgc2046.Workers.LearningProgressWorker do
  @moduledoc """
  学习 workflow 进度扫描（E-7 #122；设计 docs/01-定稿设计/学习workflow详细设计.md §4.3/§4.4）。

  Oban cron 每 5 分钟一拍（`config.exs` crontab；ApprovalExpiryWorker 同款模式），
  扫 `type=learning` 且 `status=running` 的 run，做两件事：

  1. **完成判定（D6-② discharge）**：run 绑定定义版本的 `node_def["steps"]` 中
     末个 manual step 的 `facts[step_key]` 已存在 → 调既有 `:complete` action 置
     `succeeded`（产出即工件——facts 全量即学习产物）。`save_step_output`
     保持不改状态（单一职责、终态保护不变），完成检测由本 worker 承担，
     代价是至多一个 cron 周期的延迟——BYO 协议下平台本不编排，可接受。
     定义无 manual step → 永不触发完成（skip，不报错）。

  2. **停滞升级（D6-③）**：`running` 且 facts 无新增 > 7 天（`updated_at` 代理——
     running 态下 facts 写入是唯一更新路径）→ 经 NotificationWorker 入队提醒
     报名学员（48h 提醒同款 Oban 入队模式；7 天 args-unique 保证同一 run 同一
     收件人 7 天内至多一条）。收件人守卫：反查 Enrollment 仍 `confirmed` 才提醒。
     不自动 cancel——停滞是可见性事件，干预由人/学员侧决定。

  对账接口（E-10 #125 规则编号体系；本 worker 不消费 Finding，只对齐语义）：
  - 规则①：confirmed enrollment 无 learning run（本 worker 不消费；由
    LearningInstantiator 的 warning 日志 + 报名/run 两表可扫支撑，E-10
    ReconciliationScanWorker 落地）。
  - **停滞扫描（facts 停滞 > 7 天，即本 worker 停滞提醒的同一判定）不在 E-10
    v1 规则内**——E-10 六条孤儿规则只覆盖「链路断连」（无 run / 无 deadline /
    死信 / 无定义 / 残余 run），停滞是可见性事件而非孤儿，属未来扩展，不占
    #125 规则编号。

  单记录处理失败记 warning 不中断整拍（领域 action 状态守卫幂等，并发终态变化
  属预期竞态）；整拍本身幂等（完成判定看 facts 存在性，提醒靠 args-unique 去重）。
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    # 唯一窗与 cron 周期（5 分钟）对齐：防抖重复入队/手动重触造成的并发拍
    # （ApprovalExpiryWorker 同款）。
    unique: [period: 300, states: :incomplete]

  require Ash.Query
  require Logger

  alias Cgc2046.Events.Enrollment
  alias Cgc2046.Workflows.WorkflowRun

  @stagnation_threshold_days 7

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

  @doc "停滞阈值（7 天，D6-③）；对账规则②复用同一语义。"
  def stagnant_cutoff(now \\ DateTime.utc_now()) do
    DateTime.add(now, -@stagnation_threshold_days, :day)
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

  defp maybe_complete(%WorkflowRun{} = run) do
    with step_key when is_binary(step_key) <- last_manual_step_key(run.definition),
         true <- Map.has_key?(run.facts || %{}, step_key) do
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

  # 末个 manual step（设计 §4.3）：node_def["steps"] 数组顺序即拓扑序
  # （jido_adapter #34 契约），取最后一个 type=="manual" 的 "id"。
  # node_def 形态不符契约 → nil（skip，不报错）。
  defp last_manual_step_key(%{node_def: %{"steps" => steps}}) when is_list(steps) do
    steps
    |> Enum.filter(fn
      %{"type" => "manual", "id" => id} when is_binary(id) -> true
      _ -> false
    end)
    |> List.last()
    |> case do
      %{"id" => id} -> id
      nil -> nil
    end
  end

  defp last_manual_step_key(_definition), do: nil

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
    with enrollment_id when is_binary(enrollment_id) <- enrollment_id_of(run),
         {:ok, %Enrollment{status: :confirmed} = enrollment} <- fetch_enrollment(enrollment_id) do
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
        %{"run_id" => run.id},
        :reminder_7d
      )

      :reminded
    end
  rescue
    error ->
      Logger.warning("learning stagnation reminder enqueue failed: #{Exception.message(error)}")
      :reminded
  end

  defp enrollment_id_of(%WorkflowRun{input_snapshot: input}) when is_map(input) do
    Map.get(input, "enrollment_id") || Map.get(input, :enrollment_id)
  end

  defp enrollment_id_of(_run), do: nil

  # Enrollment 是 global?(true) 租户资源，PK 全局唯一，可不带 tenant 读。
  defp fetch_enrollment(enrollment_id) do
    case Ash.get(Enrollment, enrollment_id, authorize?: false) do
      {:ok, enrollment} -> {:ok, enrollment}
      {:error, _} -> {:error, :enrollment_read_failed}
    end
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
