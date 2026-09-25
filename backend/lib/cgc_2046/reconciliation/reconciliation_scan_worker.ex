defmodule Cgc2046.Reconciliation.ReconciliationScanWorker do
  @moduledoc """
  对账扫描 worker（E-10 #125）。

  Oban cron 每 10 分钟一拍（config.exs crontab 第 5 项），扫十三条规则 →
  落 `reconciliation_findings`（`Cgc2046.Reconciliation.Finding`）。

  ## 规则（枚举见 Finding moduledoc；1-7 = E-10，8-11 = ADR-0009 U7 名额账本，12 = Fable 5 HIGH-1 缓存漂移，13 = R3 资金写频次告警）

  1. `:confirmed_enrollment_without_run` — confirmed 报名无 learning run
     （`workflow_runs.input_snapshot->>'enrollment_id'` join
     `workflow_definitions.type=learning` 存在性判定；BYO 协议下平台不编排，
     存在即非孤儿，不看 run 终态）
  2. `:pending_without_deadline` — pending 无 approval_deadline
     （四资源 UNION：enrollment / sponsorship / join_request / workspace_application；
     创建路径必写 deadline，nil 即异常）
  3. `:active_sponsorship_signal_dead` — active 赞助的 `sponsorship.active` 发布 job
     处于 discarded（PR-A 后同事务必入队，死信 = 信号从未发布 = 信号链断连；
     SignalLog 只记入向 ADR-0003，原「无 signal_log」不可实现）
  4. `:open_entity_without_research_definition` — open 实体其工作台无 published
     教研定义（U6:course 无条件;event 保留 curriculum_enabled=false 合法不命中）
  5. `:nonterminal_research_run_for_closed_entity` — closed/cancelled Event/Course
     仍有非终态教研 run（instance key `event_<id>`/`course_<id>`，reaper 同约定；
     Curriculum.Instantiator 二次校验与 INSERT 竞态 / reaper cancel 失败残余窗口兜底）
  6. `:dead_letter_job` — 死信 job（SignalPublishWorker / NotificationWorker /
     DeliveryWorker / DepositForfeitWorker；末位为押金 no-show 结算，KTD7）。
     **Pruner 7 天窗口内判定**：oban_jobs 超出 Pruner max_age（7 天）的 discarded
     历史行不报告——死信告警只覆盖可排查窗口，历史已过期行交给 Pruner 清理。
  7. `:learning_run_stalled` — learning run 停滞（E-9 #122 补差）：
     `status=running ∧ definition.type=learning ∧ updated_at 严格早于 cutoff`
     （7 天无 facts 更新）。阈值与 LearningProgressWorker 停滞提醒（D6-③）同源
     ——`Cgc2046.Learning.Runs.stagnant_cutoff/1` 单点定义，本 worker 只引用不改逻辑；
     分工：提醒归 LPW，对账可见归本规则（/admin 对账页 findings 列表）。
  8. `:open_offering_without_ledger` — open offering 无名额账本行
  9. `:ledger_occupancy_mismatch` — 账本 occupancy ≠ 占位报名计数
     （confirmed + payment_pending）
  10. `:capacity_projection_drift` — 展示投影滞后账本超一拍
     （宽限 = 一个 cron 周期，见 @drift_grace_seconds）
  11. `:occupancy_exceeds_capacity` — 账本 occupancy > capacity
     （R16/AE4 capacity 调小后的合法超员窗口看护，自然释放收敛后自消）
  12. `:ledger_cache_drift` — 账本三列缓存漂移于 offering 真值
     （status / capacity / registration_deadline 异步覆盖写的丢投窗口看护；
     无宽限——缓存≠真值即报,在途瞬时命中下一拍自消;规12 锚点缝隙修复,见 scan_rule12 注释）
  13. `:fund_action_burst` — 资金写动作频次告警（R3）：窗口内同一 actor 同类
      资金写治理动作（:order_refund / :order_refund_retry / :waive_payment）
      超阈值 → 按 actor 一行 Finding；纯查询 admin_action_logs 不动资金链路，
      首次发现补 Logger.warning（ops 告警通道），频率回落下一拍自消

  ## 刷新语义（D2）

  逐规则：命中 upsert（唯一键 (rule, entity_type, entity_id)——已存在走 :refresh
  保 first_seen_at、刷新 last_seen_at，不存在走 :create 双时间戳 = now）；本次未命中
  的行删除。**「无孤儿 → 空报告」由结构保证**：孤儿消解后下一拍即删。

  ## 平台读（specs/unique 同款：approval_expiry_worker）

  规1/2/4/5 走 Ash 查询下推（`authorize?: false` 跨租户全局读）；规3/6 经 Repo
  直查 oban_jobs，规8-12 经 Repo 直查账本 / offering 表（账本写路径全裸 SQL，
  对账读同口径）。Finding 写同样 `authorize?: false`——资源 policy 仅
  PlatformAdmin，worker 平台读旁路（D2）。
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    # 唯一窗与 cron 周期对齐：防抖重复入队/手动重触造成的并发双拍
    # （approval_expiry_worker 同款；拍内 upsert 判重 + 唯一索引兜底）。
    unique: [period: 300, states: :incomplete]

  require Logger

  alias Cgc2046.Reconciliation.Finding
  alias Cgc2046.Reconciliation.ScanDetections
  alias Cgc2046.Reconciliation.ScanDetectionsOps

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Enum.each(rules(), fn {rule, scan} ->
      apply_rule(rule, scan.())
    end)

    :ok
  end

  # 规则分派表（运行时求值：检测函数在 ScanDetections / ScanDetectionsOps，
  # #852 C9 迁出；逐规则调用 → Finding.apply_rule/3）
  defp rules do
    [
      {:confirmed_enrollment_without_run,
       fn -> ScanDetections.detect_confirmed_enrollment_without_run() end},
      {:pending_without_deadline, fn -> ScanDetections.detect_pending_without_deadline() end},
      {:active_sponsorship_signal_dead,
       fn -> ScanDetections.detect_active_sponsorship_signal_dead() end},
      # 规④/⑤ 原子名冻结（research_* 为 DB 落库枚举值，不随 PR③ 改名，
      # 冻结原因见 Reconciliation.Finding @rule_values 注释）
      {:open_entity_without_research_definition,
       fn -> ScanDetections.detect_open_entity_without_research_definition() end},
      {:nonterminal_research_run_for_closed_entity,
       fn -> ScanDetections.detect_nonterminal_research_run_for_closed_entity() end},
      {:dead_letter_job, fn -> ScanDetections.detect_dead_letter_job() end},
      {:learning_run_stalled, fn -> ScanDetections.detect_learning_run_stalled() end},
      {:open_offering_without_ledger,
       fn -> ScanDetectionsOps.detect_open_offering_without_ledger() end},
      {:ledger_occupancy_mismatch,
       fn -> ScanDetectionsOps.detect_ledger_occupancy_mismatch() end},
      {:capacity_projection_drift,
       fn -> ScanDetectionsOps.detect_capacity_projection_drift() end},
      {:occupancy_exceeds_capacity,
       fn -> ScanDetectionsOps.detect_occupancy_exceeds_capacity() end},
      {:ledger_cache_drift, fn -> ScanDetectionsOps.detect_ledger_cache_drift() end},
      {:fund_action_burst, fn -> ScanDetectionsOps.detect_fund_action_burst() end},
      {:notification_delivery_failed,
       fn -> ScanDetectionsOps.detect_notification_delivery_failed() end}
    ]
  end

  # ── 刷新语义（D2）：命中 upsert + 本次未命中删除（单源见 Finding.apply_rule/3）──

  defp apply_rule(rule, candidates) do
    Finding.apply_rule(rule, candidates,
      log_prefix: "reconciliation",
      on_create: fn rule, candidate, result -> maybe_warn_new(rule, candidate, result) end
    )
  end

  # 规13 首次发现补 ops 告警日志（Finding 面之外的「通知」通道）；其余规则
  # 与其余结果（refresh / 写失败交 handle_write 记录）不重复刷。
  defp maybe_warn_new(:fund_action_burst, candidate, {:ok, _}) do
    Logger.warning(
      "reconciliation: fund action burst — actor #{candidate.entity_id} " <>
        "exceeded threshold: #{inspect(candidate.detail["actions"])}"
    )
  end

  defp maybe_warn_new(_rule, _candidate, _result), do: :ok
end
