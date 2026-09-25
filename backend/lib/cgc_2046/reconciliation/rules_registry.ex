defmodule Cgc2046.Reconciliation.RulesRegistry do
  @moduledoc """
  对账规则统一注册表（#852 C9 Q4）——全部规则声明的单源。

  收编四个生产方的全部规则（各 worker 仍是生产者，Finding 产出调用方式
  均不变）：

  - `ReconciliationScanWorker` — Oban cron 每 10 分钟全量拍，14 条
  - `DepositForfeitWorker` — 押金 no-show 结算链回调产出，2 条（KTD7/#545）
  - `PaymentSettlementWorker` — 支付回调落账时单事件拍，1 条（R20）
  - `PaymentReconciliationWorker` — Oban 夜间 T+1 渠道账单对账，1 条（U13）

  逐条 `%{id, desc, sweep, producer}`：

  - `id` — 规则 atom，= `Finding.rule_values/0` 枚举（`reconciliation_findings.rule`
    列的 DB 落库值，atom 即 ID，编号无承载作用）
  - `desc` — 规则语义权威描述（原 Finding / 各 worker moduledoc 的规则清单
    收编于此单源；前端标签与运营文档以此为准）
  - `sweep` — 扫描模式（`:full` 全量拍 upsert + 未命中删除 / `:partial`
    残缺视图只 upsert / `:one_shot` 单事件拍，语义单源见 `Finding.apply_rule/3`；
    标注的是规则的主模式，动态降级如 :payment_recon 完整/降级切换在 desc 说明）
  - `producer` — 产出该规则 Finding 的 worker 模块

  `rules_registry_test.exs` 反射锁：注册表 atom 集 == `Finding.rule_values/0`
  全集（堵「atom 拼错静默漏报」）、各生产方使用的 atom ∈ 注册表、desc 非空、
  sweep 合法。
  """

  alias Cgc2046.Payments.Workers.DepositForfeitWorker
  alias Cgc2046.Payments.Workers.PaymentReconciliationWorker
  alias Cgc2046.Payments.Workers.PaymentSettlementWorker
  alias Cgc2046.Reconciliation.ReconciliationScanWorker

  @rules [
    %{
      id: :confirmed_enrollment_without_run,
      desc:
        "confirmed 报名无 learning run：锚点 = user × 锚 revision（双通道报名汇入同一 run，" <>
          "逐 enrollment 判定会误报汇入方；课程未发布的无锚窗口不算异常，发布后补种自愈）；" <>
          "BYO 协议下平台不编排，存在即非孤儿，不看 run 终态（E-10）",
      sweep: :full,
      producer: ReconciliationScanWorker
    },
    %{
      id: :pending_without_deadline,
      desc:
        "pending 无 approval_deadline：四资源 UNION（enrollment/sponsorship/" <>
          "join_request/workspace_application），创建路径必写 deadline，nil 即异常（E-10）",
      sweep: :full,
      producer: ReconciliationScanWorker
    },
    %{
      id: :active_sponsorship_signal_dead,
      desc:
        "active 赞助的 sponsorship.active 发布 job 处于 discarded：PR-A 后同事务必入队，" <>
          "死信 = 信号从未发布 = 信号链断连；SignalLog 只记入向（ADR-0003，" <>
          "原「无 signal_log」不可实现）（E-10）",
      sweep: :full,
      producer: ReconciliationScanWorker
    },
    %{
      id: :open_entity_without_research_definition,
      desc:
        "draft/open 实体其工作台无 published 教研定义：course 侧无条件命中" <>
          "（prep run 始于 course.created，draft 期断流即该看见）；event 保留 " <>
          "curriculum_enabled=false 合法不命中；原子名冻结 research_*" <>
          "（DB 落库枚举值，改名使存量 finding 孤儿化）（E-10/U6）",
      sweep: :full,
      producer: ReconciliationScanWorker
    },
    %{
      id: :nonterminal_research_run_for_closed_entity,
      desc:
        "closed/cancelled 实体仍有非终态教研 run：instance key event_<id>/course_<id>" <>
          "（reaper 同约定；Instantiator 二次校验与 INSERT 竞态 / reaper cancel 失败残余窗口兜底）；" <>
          "S6 起 event-only；原子名冻结 research_*（E-10）",
      sweep: :full,
      producer: ReconciliationScanWorker
    },
    %{
      id: :dead_letter_job,
      desc:
        "死信 job（SignalPublishWorker/NotificationWorker/DeliveryWorker/DepositForfeitWorker" <>
          "——末位为押金 no-show 结算 KTD7）；Pruner 7 天窗口内判定：超出 max_age 的 " <>
          "discarded 历史行不报告，交给 Pruner 清理（E-10）",
      sweep: :full,
      producer: ReconciliationScanWorker
    },
    %{
      id: :learning_run_stalled,
      desc:
        "learning run 停滞：status=running 且最后活动时间（最新 attempt created_at，" <>
          "零 attempt 回退 inserted_at）严格早于 cutoff（7 天）；阈值与 LPW 停滞提醒同源" <>
          "——Learning.Runs 单点定义，本规则只引用；提醒归 LPW，对账可见归本规则（E-9 #122/S8）",
      sweep: :full,
      producer: ReconciliationScanWorker
    },
    %{
      id: :open_offering_without_ledger,
      desc:
        "open offering 无名额账本行：launched 信号建行 / 报名懒建双路均未到达；" <>
          "信号在途窗口的瞬时 finding 下一拍自消（ADR-0009 U7 R17）",
      sweep: :full,
      producer: ReconciliationScanWorker
    },
    %{
      id: :ledger_occupancy_mismatch,
      desc:
        "账本 occupancy ≠ 占位报名计数：占位态 = confirmed + payment_pending，" <>
          "与占位/释放路径口径一致（R17）",
      sweep: :full,
      producer: ReconciliationScanWorker
    },
    %{
      id: :capacity_projection_drift,
      desc:
        "offering 展示投影滞后账本超一拍：confirmed_count / confirmed_count_sync_version " <>
          "与账本不一致且账本最近变更早于一个 cron 周期（宽限一拍对齐 10 分钟周期；R17）",
      sweep: :full,
      producer: ReconciliationScanWorker
    },
    %{
      id: :occupancy_exceeds_capacity,
      desc:
        "账本 occupancy > capacity：capacity 调小后的合法超员窗口看护，" <>
          "自然释放收敛后自消（R16/AE4）",
      sweep: :full,
      producer: ReconciliationScanWorker
    },
    %{
      id: :ledger_cache_drift,
      desc:
        "账本三列缓存（status/capacity/registration_deadline）漂移于 offering 真值：" <>
          "缓存经异步信号覆盖写，丢投不重试窗口的上游漂移看护；无宽限——缓存≠真值即报，" <>
          "在途瞬时命中下一拍自消（ADR-0009 Fable 5 HIGH-1）",
      sweep: :full,
      producer: ReconciliationScanWorker
    },
    %{
      id: :fund_action_burst,
      desc:
        "资金写动作频次告警（R3）：窗口内同一 actor 同类资金写治理动作" <>
          "（:order_refund/:order_refund_retry/:waive_payment）超阈值（默认 1h/5 笔，app env 可调）" <>
          " → 按 actor 一行 Finding；纯查询 admin_action_logs 不动资金链路，" <>
          "首次发现补 Logger.warning，频率回落下一拍自消",
      sweep: :full,
      producer: ReconciliationScanWorker
    },
    %{
      id: :notification_delivery_failed,
      desc:
        "通知 outbox 终态失败面（#556）：24h 内落 :failed 的 notification_deliveries 行" <>
          "逐行出 Finding（entity = :notification_delivery）；窗口语义自清——超窗未命中删除；" <>
          "终态化本体在 DeliveryWorker 末拍",
      sweep: :full,
      producer: ReconciliationScanWorker
    },
    %{
      id: :payment_amount_mismatch,
      desc:
        "收款金额与订单不符（R20）：支付回调落账 worker 回查渠道 total ≠ 订单 " <>
          "amount_cents → 拒绝落账 + 单事件拍 Finding 兜底（detail 带双方金额）；" <>
          "entity = :payment_order；:one_shot——重复命中刷新 last_seen_at，" <>
          "无全量视图不做 stale 删除",
      sweep: :one_shot,
      producer: PaymentSettlementWorker
    },
    %{
      id: :payment_recon,
      desc:
        "缴费对账规⑦（U13/KTD11/R23）：夜间 T+1 拉两渠道账单与本地订单比对，五类差异" <>
          "（channel_only 渠道有我无 / local_paid_missing 我 paid 渠道无 / amount_mismatch " <>
          "金额不符 / pending_overdue 超期 / refunding_stuck 卡死）落 Finding" <>
          "（entity = :payment_order，detail.kind 区分）；主模式 :full（含未命中删除），" <>
          "账单拉取失败降级纯本地面 :partial（残缺视图跳过删除，防真差异被误删）",
      sweep: :full,
      producer: PaymentReconciliationWorker
    },
    %{
      id: :deposit_settlement_unanchored,
      desc:
        "押金 no-show 结算无锚（U8/KTD7）：closed 场 ends_at 为空而名下仍有 paid 押金单" <>
          "——结算锚点缺失、订单会静默滞留；entity = 场（:event）；刷新语义同 D2" <>
          "（命中 upsert / 未命中删除），由结算拍回调产出（非 cron 扫描）",
      sweep: :full,
      producer: DepositForfeitWorker
    },
    %{
      id: :deposit_forfeit_batch_alert,
      desc:
        "单场押金没收批量告警（#545）：该 event 名下 forfeited 押金单计数 ≥5" <>
          "（阈值 5，101 场规模硬编码不配置化）——一场没收过半即异常信号" <>
          "（错配置 / ends_at 误操作 / 现场执行失败），需运营核查；状态性口径：" <>
          "unforfeit 救济降到阈值下自动消解（刷新语义删除）；entity = 场（:event）",
      sweep: :full,
      producer: DepositForfeitWorker
    }
  ]

  @doc "全部规则声明（id/desc/sweep/producer），= Finding.rule_values/0 全集。"
  @spec all() :: [map()]
  def all, do: @rules

  @doc "全部规则 atom。"
  @spec ids() :: [atom()]
  def ids, do: Enum.map(@rules, & &1.id)

  @doc "按 id 取单条声明（scan worker rules/0 注入 desc/sweep 消费）。"
  @spec fetch!(atom()) :: map()
  def fetch!(id) do
    Enum.find(@rules, &(&1.id == id)) ||
      raise ArgumentError, "unknown reconciliation rule: #{inspect(id)}"
  end

  @doc "指定生产方的规则（反射测试断言 worker 声明表与注册表一致消费）。"
  @spec by_producer(module()) :: [map()]
  def by_producer(producer), do: Enum.filter(@rules, &(&1.producer == producer))
end
