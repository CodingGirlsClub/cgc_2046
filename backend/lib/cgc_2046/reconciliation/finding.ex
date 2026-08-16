defmodule Cgc2046.Reconciliation.Finding do
  @moduledoc """
  对账扫描发现（E-10 #125；设计 docs/plans/2026-08-15-011-e10-reconciliation-scan.md D1）。

  平台级孤儿报告：`Cgc2046.Workers.ReconciliationScanWorker` 每 10 分钟扫七条规则，
  命中落本表。**刷新语义**（D2）：命中 upsert（保 first_seen_at、刷新 last_seen_at），
  本次未命中删除——「无孤儿 → 空报告」由结构保证。

  ## 七规则（rule 枚举）

  1. `:confirmed_enrollment_without_run` — confirmed 报名无 learning run
     （`workflow_runs.input_snapshot` join `workflow_definitions.type=learning`，
     BYO 协议下平台不编排，存在即非孤儿，不看 run 终态）
  2. `:pending_without_deadline` — pending 无 approval_deadline
     （enrollment/sponsorship/join_request/workspace_application 四资源 UNION；
     创建路径必写 deadline，nil 即异常）
  3. `:active_sponsorship_signal_dead` — active 赞助的 `sponsorship.active` 发布 job
     处于 discarded（PR-A 后同事务必入队，死信 = 信号从未发布 = 信号链断连；
     SignalLog 只记入向，ADR-0003，原「无 signal_log」不可实现）
  4. `:open_entity_without_research_definition` — open 实体其工作台无 published
     教研定义（U6:course 无条件;event 保留 research_enabled=false 合法不命中）
  5. `:nonterminal_research_run_for_closed_entity` — closed/cancelled Event/Course
     仍有非终态教研 run（instance key `event_<id>`/`course_<id>`，reaper 同约定）
  6. `:dead_letter_job` — 信号族死信（SignalPublishWorker / NotificationWorker，
     Pruner 7 天窗口内判定，moduledoc 见 worker）
  7. `:learning_run_stalled` — learning run 停滞（`status=running` 且 `updated_at`
     严格早于 `LearningProgress.stagnant_cutoff/1`，即 7 天无 facts 更新；
     与 LearningProgressWorker 停滞提醒（D6-③）同源判定，阈值只在一处定义）

  规3/规6 的有效窗口均受 Oban Pruner（max_age 7 天）约束：discarded job 被
  Pruner 删除后，未消解的孤儿会从报告静默消失（刷新语义按未命中删除，视为
  已消解）——窗口语义，非 bug。

  ## 平台管理面

  全局资源（无 tenant，workspace_id 仅信息列）；read 仅 PlatformAdmin
  （/admin/reconciliation 对账页消费，signal_log.ex 同款 policy）。worker 平台读
  走 `authorize?: false`（D2），本资源不暴露任何 GraphQL mutation。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Api

  @rule_values [
    :confirmed_enrollment_without_run,
    :pending_without_deadline,
    :active_sponsorship_signal_dead,
    :open_entity_without_research_definition,
    :nonterminal_research_run_for_closed_entity,
    :dead_letter_job,
    :learning_run_stalled,
    # 缴费闭环（U7 落账前置兜底 / U13 规⑦）
    :payment_amount_mismatch,
    :payment_recon
  ]

  @entity_type_values [
    :enrollment,
    :sponsorship,
    :join_request,
    :workspace_application,
    :event,
    :course,
    :oban_job,
    :workflow_run,
    :payment_order
  ]

  attributes do
    uuid_primary_key(:id)

    attribute(:rule, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: @rule_values],
      description: "对账规则枚举（七条）"
    )

    attribute(:entity_type, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: @entity_type_values],
      description: "孤儿实体类型"
    )

    attribute(:entity_id, :string,
      allow_nil?: false,
      public?: true,
      description: "孤儿实体 ID（UUID 或 oban_jobs 数字 ID 的字符串形态）"
    )

    attribute(:workspace_id, :uuid,
      allow_nil?: true,
      public?: true,
      description: "所属工作台（可空：全局实体如工作台创建申请、死信 job 无租户）"
    )

    attribute(:detail, :map,
      public?: true,
      default: %{},
      description: "发现上下文（title/run_id/job_id/cause 等，排查用）"
    )

    attribute(:first_seen_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "首次发现时间（刷新语义：命中只更新 last_seen_at，保首次）"
    )

    attribute(:last_seen_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "最近发现时间（每次扫描命中刷新）"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    # 刷新语义的判重键：同规则同实体至多一行（worker 命中按此 upsert）
    identity(:unique_finding, [:rule, :entity_type, :entity_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      description("对账扫描命中：登记发现（first_seen_at = last_seen_at = now）")
      accept([:rule, :entity_type, :entity_id, :workspace_id, :detail])

      # 同一 now：first_seen_at 与 last_seen_at 逐值相等（首次发现）
      change(fn changeset, _context ->
        now = DateTime.utc_now()

        changeset
        |> Ash.Changeset.force_change_attribute(:first_seen_at, now)
        |> Ash.Changeset.force_change_attribute(:last_seen_at, now)
      end)
    end

    update :refresh do
      description("对账扫描再命中：刷新 last_seen_at（保 first_seen_at），覆盖 detail")
      accept([:workspace_id, :detail])
      change(set_attribute(:last_seen_at, &DateTime.utc_now/0))
    end
  end

  postgres do
    table("reconciliation_findings")
    repo(Cgc2046.Repo)

    custom_indexes do
      # 按规则扫描 + 列表按 last_seen_at 倒序
      index([:rule, :last_seen_at])
      # /admin/reconciliation 按 workspace 过滤
      index([:workspace_id])
    end
  end

  policies do
    # 平台级报告：仅平台管理员可读（对账页消费）；扫描 worker 走 authorize?: false
    # 平台读（D2）。create/refresh 亦仅 PlatformAdmin——worker 之外无合法写入口。
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end
  end
end
