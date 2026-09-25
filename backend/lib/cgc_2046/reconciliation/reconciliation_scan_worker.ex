defmodule Cgc2046.Reconciliation.ReconciliationScanWorker do
  @moduledoc """
  对账扫描 worker（E-10 #125）。

  Oban cron 每 10 分钟一拍（config.exs crontab 第 5 项），扫本 worker 声明的
  规则 → 落 `reconciliation_findings`（`Cgc2046.Reconciliation.Finding`）。
  **规则清单与语义见 `rules/0` 声明（单源）**——检测实现分布在
  `ScanDetections`（实体/信号/停滞域）与 `ScanDetectionsOps`（账本/运营
  告警窗域），逐规则 `%{id, desc, sweep, detect}` 声明，不在 moduledoc 重复
  维护清单（#852 C9：消除「枚举 / 分发表 / moduledoc 清单」多处漂移）。

  ## 刷新语义（D2）

  逐规则：命中 upsert（唯一键 (rule, entity_type, entity_id)——已存在走 :refresh
  保 first_seen_at、刷新 last_seen_at，不存在走 :create 双时间戳 = now）；本次未命中
  的行删除。**「无孤儿 → 空报告」由结构保证**：孤儿消解后下一拍即删。

  ## 平台读（specs/unique 同款：approval_expiry_worker）

  实体域检测（confirmed_enrollment_without_run / pending_without_deadline /
  research_* 两域）走 Ash 查询下推（`authorize?: false` 跨租户全局读）；
  信号死信与账本/运营域检测经 Repo 直查（oban_jobs / 账本 / offering /
  操作日志 / 投递表——账本写路径全裸 SQL，对账读同口径）。Finding 写同样
  `authorize?: false`——资源 policy 仅 PlatformAdmin，worker 平台读旁路（D2）。
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
    Enum.each(rules(), fn rule ->
      apply_rule(rule.id, rule.detect.())
    end)

    :ok
  end

  # 规则声明表（#852 C9 形态 A）——单源：%{id, desc, sweep, detect}。
  # id = Finding.rule_values 枚举 atom（DB 落库值）；desc = 规则语义（原
  # moduledoc 规则清单并入）；sweep = 扫描模式（本 worker 全量拍 :full）；
  # detect = 检测函数捕获（运行时求值）。driver（perform/apply_rule）只消费
  # 声明不感知具体规则——新规则 = 一条声明 + 一个 detect 函数。
  defp rules do
    [
      %{
        id: :confirmed_enrollment_without_run,
        desc:
          "confirmed 报名无 learning run：锚点 = user × 锚 revision（双通道报名汇入同一 run，" <>
            "逐 enrollment 判定会误报汇入方；课程未发布的无锚窗口不算异常，发布后补种自愈）；" <>
            "BYO 协议下平台不编排，存在即非孤儿，不看 run 终态（E-10）",
        sweep: :full,
        detect: &ScanDetections.detect_confirmed_enrollment_without_run/0
      },
      %{
        id: :pending_without_deadline,
        desc:
          "pending 无 approval_deadline：四资源 UNION（enrollment/sponsorship/" <>
            "join_request/workspace_application），创建路径必写 deadline，nil 即异常（E-10）",
        sweep: :full,
        detect: &ScanDetections.detect_pending_without_deadline/0
      },
      %{
        id: :active_sponsorship_signal_dead,
        desc:
          "active 赞助的 sponsorship.active 发布 job 处于 discarded：PR-A 后同事务必入队，" <>
            "死信 = 信号从未发布 = 信号链断连；SignalLog 只记入向（ADR-0003，" <>
            "原「无 signal_log」不可实现）（E-10）",
        sweep: :full,
        detect: &ScanDetections.detect_active_sponsorship_signal_dead/0
      },
      %{
        id: :open_entity_without_research_definition,
        desc:
          "draft/open 实体其工作台无 published 教研定义：course 侧无条件命中" <>
            "（prep run 始于 course.created，draft 期断流即该看见）；event 保留 " <>
            "curriculum_enabled=false 合法不命中；原子名冻结 research_*" <>
            "（DB 落库枚举值，改名使存量 finding 孤儿化）（E-10/U6）",
        sweep: :full,
        detect: &ScanDetections.detect_open_entity_without_research_definition/0
      },
      %{
        id: :nonterminal_research_run_for_closed_entity,
        desc:
          "closed/cancelled 实体仍有非终态教研 run：instance key event_<id>/course_<id>" <>
            "（reaper 同约定；Instantiator 二次校验与 INSERT 竞态 / reaper cancel 失败残余窗口兜底）；" <>
            "S6 起 event-only；原子名冻结 research_*（E-10）",
        sweep: :full,
        detect: &ScanDetections.detect_nonterminal_research_run_for_closed_entity/0
      },
      %{
        id: :dead_letter_job,
        desc:
          "死信 job（SignalPublishWorker/NotificationWorker/DeliveryWorker/DepositForfeitWorker" <>
            "——末位为押金 no-show 结算 KTD7）；Pruner 7 天窗口内判定：超出 max_age 的 " <>
            "discarded 历史行不报告，交给 Pruner 清理（E-10）",
        sweep: :full,
        detect: &ScanDetections.detect_dead_letter_job/0
      },
      %{
        id: :learning_run_stalled,
        desc:
          "learning run 停滞：status=running 且最后活动时间（最新 attempt created_at，" <>
            "零 attempt 回退 inserted_at）严格早于 cutoff（7 天）；阈值与 LPW 停滞提醒同源" <>
            "——Learning.Runs 单点定义，本规则只引用；提醒归 LPW，对账可见归本规则（E-9 #122/S8）",
        sweep: :full,
        detect: &ScanDetections.detect_learning_run_stalled/0
      },
      %{
        id: :open_offering_without_ledger,
        desc:
          "open offering 无名额账本行：launched 信号建行 / 报名懒建双路均未到达；" <>
            "信号在途窗口的瞬时 finding 下一拍自消（ADR-0009 U7 R17）",
        sweep: :full,
        detect: &ScanDetectionsOps.detect_open_offering_without_ledger/0
      },
      %{
        id: :ledger_occupancy_mismatch,
        desc:
          "账本 occupancy ≠ 占位报名计数：占位态 = confirmed + payment_pending，" <>
            "与占位/释放路径口径一致（R17）",
        sweep: :full,
        detect: &ScanDetectionsOps.detect_ledger_occupancy_mismatch/0
      },
      %{
        id: :capacity_projection_drift,
        desc:
          "offering 展示投影滞后账本超一拍：confirmed_count / confirmed_count_sync_version " <>
            "与账本不一致且账本最近变更早于一个 cron 周期（宽限一拍对齐 10 分钟周期；R17）",
        sweep: :full,
        detect: &ScanDetectionsOps.detect_capacity_projection_drift/0
      },
      %{
        id: :occupancy_exceeds_capacity,
        desc:
          "账本 occupancy > capacity：capacity 调小后的合法超员窗口看护，" <>
            "自然释放收敛后自消（R16/AE4）",
        sweep: :full,
        detect: &ScanDetectionsOps.detect_occupancy_exceeds_capacity/0
      },
      %{
        id: :ledger_cache_drift,
        desc:
          "账本三列缓存（status/capacity/registration_deadline）漂移于 offering 真值：" <>
            "缓存经异步信号覆盖写，丢投不重试窗口的上游漂移看护；无宽限——缓存≠真值即报，" <>
            "在途瞬时命中下一拍自消（ADR-0009 Fable 5 HIGH-1）",
        sweep: :full,
        detect: &ScanDetectionsOps.detect_ledger_cache_drift/0
      },
      %{
        id: :fund_action_burst,
        desc:
          "资金写动作频次告警（R3）：窗口内同一 actor 同类资金写治理动作" <>
            "（:order_refund/:order_refund_retry/:waive_payment）超阈值（默认 1h/5 笔，app env 可调）" <>
            " → 按 actor 一行 Finding；纯查询 admin_action_logs 不动资金链路，" <>
            "首次发现补 Logger.warning，频率回落下一拍自消",
        sweep: :full,
        detect: &ScanDetectionsOps.detect_fund_action_burst/0
      },
      %{
        id: :notification_delivery_failed,
        desc:
          "通知 outbox 终态失败面（#556）：24h 内落 :failed 的 notification_deliveries 行" <>
            "逐行出 Finding（entity = :notification_delivery）；窗口语义自清——超窗未命中删除；" <>
            "终态化本体在 DeliveryWorker 末拍",
        sweep: :full,
        detect: &ScanDetectionsOps.detect_notification_delivery_failed/0
      }
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
