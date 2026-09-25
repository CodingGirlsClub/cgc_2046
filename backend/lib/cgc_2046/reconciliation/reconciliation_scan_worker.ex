defmodule Cgc2046.Reconciliation.ReconciliationScanWorker do
  @moduledoc """
  对账扫描 worker（E-10 #125）。

  Oban cron 每 10 分钟一拍（config.exs crontab 第 5 项），扫本 worker 声明的
  规则 → 落 `reconciliation_findings`（`Cgc2046.Reconciliation.Finding`）。
  **规则清单与语义单源见 `RulesRegistry`**——本 worker 的 `rules/0` 只声明
  id + detect 绑定（检测实现分布在 `ScanDetections`（实体/信号/停滞域）与
  `ScanDetectionsOps`（账本/运营告警窗域）），desc/sweep 自注册表注入为
  `%{id, desc, sweep, detect}`，不在 moduledoc 重复维护清单（#852 C9：
  消除「枚举 / 分发表 / moduledoc 清单」多处漂移）。

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
  alias Cgc2046.Reconciliation.RulesRegistry
  alias Cgc2046.Reconciliation.ScanDetections
  alias Cgc2046.Reconciliation.ScanDetectionsOps

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Enum.each(rules(), fn rule ->
      apply_rule(rule.id, rule.detect.())
    end)

    :ok
  end

  # 规则声明表（#852 C9 形态 A）——detect 捕获在 worker（检测函数绑定），
  # desc/sweep 单源注入自 RulesRegistry（C9 Q4 描述单源，防多处漂移）。
  # driver（perform/apply_rule）只消费声明不感知具体规则——新规则 =
  # 注册表一条声明 + 一个 detect 函数 + 一条绑定。
  # @doc false public 只读访问器（先例 dead_letter_workers/0）：反射测试
  # 断言「声明表 id 集 == 注册表 by_producer 子集」消费。
  @doc false
  @spec rules() :: [map()]
  def rules do
    [
      %{
        id: :confirmed_enrollment_without_run,
        detect: &ScanDetections.detect_confirmed_enrollment_without_run/0
      },
      %{id: :pending_without_deadline, detect: &ScanDetections.detect_pending_without_deadline/0},
      %{
        id: :active_sponsorship_signal_dead,
        detect: &ScanDetections.detect_active_sponsorship_signal_dead/0
      },
      %{
        id: :open_entity_without_research_definition,
        detect: &ScanDetections.detect_open_entity_without_research_definition/0
      },
      %{
        id: :nonterminal_research_run_for_closed_entity,
        detect: &ScanDetections.detect_nonterminal_research_run_for_closed_entity/0
      },
      %{id: :dead_letter_job, detect: &ScanDetections.detect_dead_letter_job/0},
      %{id: :learning_run_stalled, detect: &ScanDetections.detect_learning_run_stalled/0},
      %{
        id: :open_offering_without_ledger,
        detect: &ScanDetectionsOps.detect_open_offering_without_ledger/0
      },
      %{
        id: :ledger_occupancy_mismatch,
        detect: &ScanDetectionsOps.detect_ledger_occupancy_mismatch/0
      },
      %{
        id: :capacity_projection_drift,
        detect: &ScanDetectionsOps.detect_capacity_projection_drift/0
      },
      %{
        id: :occupancy_exceeds_capacity,
        detect: &ScanDetectionsOps.detect_occupancy_exceeds_capacity/0
      },
      %{id: :ledger_cache_drift, detect: &ScanDetectionsOps.detect_ledger_cache_drift/0},
      %{id: :fund_action_burst, detect: &ScanDetectionsOps.detect_fund_action_burst/0},
      %{
        id: :notification_delivery_failed,
        detect: &ScanDetectionsOps.detect_notification_delivery_failed/0
      }
    ]
    |> Enum.map(fn decl ->
      Map.merge(decl, Map.take(RulesRegistry.fetch!(decl.id), [:desc, :sweep]))
    end)
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
