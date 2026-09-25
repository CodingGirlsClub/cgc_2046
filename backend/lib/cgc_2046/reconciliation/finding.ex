defmodule Cgc2046.Reconciliation.Finding do
  @moduledoc """
  对账扫描发现（E-10 #125）。

  平台级孤儿报告：四个生产方 worker 命中规则落本表——
  `ReconciliationScanWorker`（Oban cron 每 10 分钟扫描）、
  `Cgc2046.Payments.Workers.DepositForfeitWorker`（押金结算链回调）、
  `Cgc2046.Payments.Workers.PaymentSettlementWorker`（落账单事件）、
  `Cgc2046.Payments.Workers.PaymentReconciliationWorker`（夜间 T+1 账单对账）。

  **规则清单与语义单源见 `Cgc2046.Reconciliation.RulesRegistry`**——
  注册表 id 与本资源 rule 枚举（@rule_values）一一对应（反射测试锁全集），
  desc 为规则语义权威描述，不在本 moduledoc 重复维护编号清单（#852 C9）。

  **刷新语义**（D2，单源 `apply_rule/3`）：命中 upsert（保 first_seen_at、
  刷新 last_seen_at），本次未命中删除——「无孤儿 → 空报告」由结构保证；
  残缺视图 / 单事件拍经 sweep 跳过删除（:partial / :one_shot，#848）。

  :active_sponsorship_signal_dead 与 :dead_letter_job 的有效窗口均受
  Oban Pruner（max_age 7 天）约束：discarded job 被 Pruner 删除后，未消解的
  孤儿会从报告静默消失（刷新语义按未命中删除，视为已消解）——窗口语义，非 bug。

  ## 平台管理面

  全局资源（无 tenant，workspace_id 仅信息列）；read 仅 PlatformAdmin
  （/admin/reconciliation 对账页消费，signal_log.ex 同款 policy）。worker 平台读
  走 `authorize?: false`（D2），本资源不暴露任何 GraphQL mutation。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Reconciliation

  require Logger
  require Ash.Query

  @rule_values [
    :confirmed_enrollment_without_run,
    :pending_without_deadline,
    :active_sponsorship_signal_dead,
    # 冻结（ADR-0009 PR③ research→curriculum 改名不溯及）：规④/⑤ 原子是
    # reconciliation_findings.rule 列的 DB 落库枚举值，改名会使存量 finding 孤儿化，
    # 原子名保留 research_* 原样（语义见 RulesRegistry 对应 desc）
    :open_entity_without_research_definition,
    :nonterminal_research_run_for_closed_entity,
    :dead_letter_job,
    :learning_run_stalled,
    # 缴费闭环（U7 落账前置兜底 / U13 规⑦）
    :payment_amount_mismatch,
    :payment_recon,
    # ADR-0009 PR⑤ U7（R17）：名额账本 / 投影对账四规则
    :open_offering_without_ledger,
    :ledger_occupancy_mismatch,
    :capacity_projection_drift,
    :occupancy_exceeds_capacity,
    # ADR-0009 Fable 5 HIGH-1：账本缓存 vs offering 真值的上游漂移看护
    :ledger_cache_drift,
    # 规13（R3）：资金写动作频次告警（同 actor 窗口内同类资金写超阈值）
    :fund_action_burst,
    # 规14（U8/KTD7）：押金 no-show 结算无锚（closed 场 ends_at 为空而仍有
    # paid 押金单；由 DepositForfeitWorker 产出，非本扫描 worker 的规则表）
    :deposit_settlement_unanchored,
    # 规15（#556）：通知 outbox 终态失败面——24h 内落 :failed 的
    # notification_deliveries 行（末拍终态化由 DeliveryWorker 承担）；窗口
    # 语义自清（超窗未命中删除，与 Oban Pruner 窗口注释同义）
    :notification_delivery_failed,
    # 规16（#545）：单场押金没收批量告警——forfeited 押金单计数 ≥5 的场
    # （状态性口径：命中条件持续到 unforfeit 救济降到阈值下，刷新语义自愈）。
    # 由 DepositForfeitWorker 产出（同规14 宿主，非本扫描 worker 的规则表）
    :deposit_forfeit_batch_alert
  ]
  # 合法规则枚举的对外读面（admin_list_reconciliation_findings 过滤校验消费；
  # @doc false public 先例同 Runs.fetch_learning_definition）
  @doc false
  @spec rule_values() :: [atom()]
  def rule_values, do: @rule_values
  # sweep 模式（#848）：full = 全量拍（upsert + 未命中删除，默认）；partial /
  # one_shot = 跳过删除（前者扫描面残缺，后者单事件触发无全量视图）
  @sweep_values [:full, :partial, :one_shot]

  @doc """
  D2 刷新语义的共享驱动：命中 upsert（保 `first_seen_at`、刷 `last_seen_at`）；
  全量拍（`:full`）删除本次未命中，其余 sweep 模式见 `opts`。

  `candidates` 为 map 列表（`entity_type` / `entity_id` / `workspace_id` / `detail`）。
  - `:on_create` — `(rule, candidate, result) -> any`，create 尝试后的回调
    （扫描侧与押金侧各自发「首次发现」warning）
  - `:sweep` — `:full | :partial | :one_shot`（默认 `:full`）。`:full` 为全量
    拍：upsert + 未命中删除。`:partial`（降级拍，账单面残缺）与 `:one_shot`
    （单事件拍，如回调金额不符）只 upsert、不删——「未命中即删」仅对完整
    命中视图成立；非法值 raise `ArgumentError`

  一拍只读一次同规则 findings，既用于 upsert 判定也用于 stale 清理：同规则只有
  一个写入者（各 worker 规则互斥），拍内无并发同规则写者，与逐候选读等价。
  写失败只 warning 不上抛（本函数不回滚扫描拍）；`Ash.read!` 失败按原语义上抛。
  """
  @spec apply_rule(atom(), [map()], keyword()) :: :ok
  def apply_rule(rule, candidates, opts \\ []) do
    prefix = Keyword.get(opts, :log_prefix, "reconciliation")
    on_create = Keyword.get(opts, :on_create)
    sweep = fetch_sweep!(opts)
    findings = findings_by_entity(rule)

    Enum.each(candidates, &upsert_finding(rule, &1, findings, prefix, on_create))

    # 降级拍 / 单事件拍无完整命中视图：跳过 stale 删除
    if sweep == :full, do: delete_stale(rule, candidates, findings, prefix)

    :ok
  end

  defp fetch_sweep!(opts) do
    case Keyword.get(opts, :sweep, :full) do
      sweep when sweep in @sweep_values ->
        sweep

      other ->
        raise ArgumentError,
              "unknown sweep mode: #{inspect(other)} (expected one of #{inspect(@sweep_values)})"
    end
  end

  defp findings_by_entity(rule) do
    __MODULE__
    |> Ash.Query.filter(rule == ^rule)
    |> Ash.read!(authorize?: false)
    |> Map.new(fn finding -> {{finding.entity_type, finding.entity_id}, finding} end)
  end

  defp upsert_finding(rule, candidate, findings, prefix, on_create) do
    key = {candidate.entity_type, candidate.entity_id}

    case Map.get(findings, key) do
      nil ->
        result =
          __MODULE__
          |> Ash.Changeset.for_create(:create, %{
            rule: rule,
            entity_type: candidate.entity_type,
            entity_id: candidate.entity_id,
            workspace_id: candidate.workspace_id,
            detail: candidate.detail
          })
          |> Ash.create(authorize?: false)

        if on_create, do: on_create.(rule, candidate, result)
        handle_write(result, rule, prefix, candidate.entity_type, candidate.entity_id)

      finding ->
        finding
        |> Ash.Changeset.for_update(:refresh, %{
          workspace_id: candidate.workspace_id,
          detail: candidate.detail
        })
        |> Ash.update(authorize?: false)
        |> handle_write(rule, prefix, candidate.entity_type, candidate.entity_id)
    end
  end

  defp handle_write(result, rule, prefix, entity_type, entity_id) do
    case result do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "#{prefix}: #{rule} upsert failed for #{entity_type} #{entity_id}: #{inspect(error)}"
        )

        :ok
    end
  end

  # 本次未命中的行删除：无孤儿 → 空报告由结构保证
  defp delete_stale(rule, candidates, findings, prefix) do
    current =
      MapSet.new(candidates, fn candidate -> {candidate.entity_type, candidate.entity_id} end)

    Enum.each(findings, fn {{entity_type, entity_id} = key, finding} ->
      unless MapSet.member?(current, key) do
        case Ash.destroy(finding, authorize?: false) do
          :ok ->
            :ok

          {:error, error} ->
            Logger.warning(
              "#{prefix}: #{rule} stale delete failed for #{entity_type} #{entity_id}: " <>
                "#{inspect(error)}"
            )
        end
      end
    end)
  end

  @entity_type_values [
    :enrollment,
    :sponsorship,
    :join_request,
    :workspace_application,
    :event,
    :course,
    :oban_job,
    :workflow_run,
    :payment_order,
    # 规13 的操作人（actor）实体
    :user,
    # 规15 的通知投递行（notification_deliveries）
    :notification_delivery
  ]

  attributes do
    uuid_primary_key(:id)

    attribute(:rule, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: @rule_values],
      description: "对账规则枚举（见 moduledoc 规则清单）"
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
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end
end
