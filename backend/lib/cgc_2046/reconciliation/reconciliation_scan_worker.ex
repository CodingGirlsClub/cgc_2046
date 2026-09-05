defmodule Cgc2046.Reconciliation.ReconciliationScanWorker do
  @moduledoc """
  对账扫描 worker（E-10 #125）。

  Oban cron 每 10 分钟一拍（config.exs crontab 第 5 项），扫十二条规则 →
  落 `reconciliation_findings`（`Cgc2046.Reconciliation.Finding`）。

  ## 规则（枚举见 Finding moduledoc；1-7 = E-10，8-11 = ADR-0009 U7 名额账本，12 = Fable 5 HIGH-1 缓存漂移）

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
  6. `:dead_letter_job` — 信号族死信（SignalPublishWorker / NotificationWorker）。
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

  require Ash.Query
  require Logger

  alias Cgc2046.Accounts.JoinRequest
  alias Cgc2046.Accounts.WorkspaceApplication
  alias Cgc2046.Courses.Course
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Events.Event
  alias Cgc2046.Sponsorship.Sponsorship
  alias Cgc2046.Reconciliation.Finding
  alias Cgc2046.Repo
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun

  # 规3/6 判定的信号族 worker 白名单（NotificationWorker 含提醒/审批结果全部通知）
  @dead_letter_workers [
    "Cgc2046.Workflows.SignalPublishWorker",
    "Cgc2046.Notifications.NotificationWorker"
  ]

  # 白名单只读访问器（ADR-0010 W1):worker 改名后字符串易漂移,测试经本函数
  # 断言「每个白名单模块真实存在」,杜绝「字符串漂移→规6 失明」形状复发。
  @doc false
  def dead_letter_workers, do: @dead_letter_workers

  # 规6 死信窗口：与 Oban Pruner max_age（7 天，config.exs）对齐
  @dead_letter_window_days 7

  # 规10 漂移宽限：R17「超 N 拍」与 cron 周期（10 分钟一拍）对齐取一拍——
  # 异步信号在途（capacity.synced / 缓存覆盖写）属正常窗口，账本最近变更
  # 早于一个周期仍漂移才告警。规12 不用本常量（无宽限，见 scan_rule12 注释）
  @drift_grace_seconds 600

  @non_terminal_statuses [:pending, :running, :waiting]

  @active_signal "sponsorship.active"

  # 规2 四资源 UNION（每行 = 一个 pending 面；WorkspaceApplication 无 workspace_id，
  # 发现记录的 workspace_id 列留空）
  @pending_deadline_specs [
    {Enrollment, :enrollment},
    {Sponsorship, :sponsorship},
    {JoinRequest, :join_request},
    {WorkspaceApplication, :workspace_application}
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Enum.each(rules(), fn {rule, scan} ->
      apply_rule(rule, scan.())
    end)

    :ok
  end

  # 规则分派表（运行时求值：scan_ruleN 为私有函数，编译期前向引用不可行）
  defp rules do
    [
      {:confirmed_enrollment_without_run, fn -> scan_rule1() end},
      {:pending_without_deadline, fn -> scan_rule2() end},
      {:active_sponsorship_signal_dead, fn -> scan_rule3() end},
      # 规④/⑤ 原子名冻结（research_* 为 DB 落库枚举值，不随 PR③ 改名，
      # 冻结原因见 Reconciliation.Finding @rule_values 注释）
      {:open_entity_without_research_definition, fn -> scan_rule4() end},
      {:nonterminal_research_run_for_closed_entity, fn -> scan_rule5() end},
      {:dead_letter_job, fn -> scan_rule6() end},
      {:learning_run_stalled, fn -> scan_rule7() end},
      {:open_offering_without_ledger, fn -> scan_rule8() end},
      {:ledger_occupancy_mismatch, fn -> scan_rule9() end},
      {:capacity_projection_drift, fn -> scan_rule10() end},
      {:occupancy_exceeds_capacity, fn -> scan_rule11() end},
      {:ledger_cache_drift, fn -> scan_rule12() end}
    ]
  end

  # ── 刷新语义（D2）：命中 upsert + 本次未命中删除 ------------------------------

  defp apply_rule(rule, candidates) do
    Enum.each(candidates, &upsert_finding(rule, &1))
    delete_stale(rule, candidates)
  end

  defp upsert_finding(rule, candidate) do
    case existing_finding(rule, candidate.entity_type, candidate.entity_id) do
      nil ->
        Finding
        |> Ash.Changeset.for_create(:create, %{
          rule: rule,
          entity_type: candidate.entity_type,
          entity_id: candidate.entity_id,
          workspace_id: candidate.workspace_id,
          detail: candidate.detail
        })
        |> Ash.create(authorize?: false)
        |> handle_write(rule, candidate.entity_type, candidate.entity_id)

      finding ->
        finding
        |> Ash.Changeset.for_update(:refresh, %{
          workspace_id: candidate.workspace_id,
          detail: candidate.detail
        })
        |> Ash.update(authorize?: false)
        |> handle_write(rule, candidate.entity_type, candidate.entity_id)
    end
  end

  defp handle_write(result, rule, entity_type, entity_id) do
    case result do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "reconciliation: #{rule} upsert failed for #{entity_type} #{entity_id}: #{inspect(error)}"
        )

        :ok
    end
  end

  defp existing_finding(rule, entity_type, entity_id) do
    case Finding
         |> Ash.Query.filter(
           rule == ^rule and entity_type == ^entity_type and entity_id == ^entity_id
         )
         |> Ash.read_one(authorize?: false) do
      {:ok, finding} -> finding
      {:error, _error} -> nil
    end
  end

  # 本次未命中的行删除：无孤儿 → 空报告由结构保证
  defp delete_stale(rule, candidates) do
    current =
      MapSet.new(candidates, fn candidate ->
        {candidate.entity_type, candidate.entity_id}
      end)

    Finding
    |> Ash.Query.filter(rule == ^rule)
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn finding ->
      key = {finding.entity_type, finding.entity_id}

      unless MapSet.member?(current, key) do
        case Ash.destroy(finding, authorize?: false) do
          :ok ->
            :ok

          {:error, error} ->
            Logger.warning(
              "reconciliation: #{rule} stale delete failed for #{finding.entity_type} " <>
                "#{finding.entity_id}: #{inspect(error)}"
            )
        end
      end
    end)
  end

  # ── 规1：confirmed enrollment 无 learning run -------------------------------

  defp scan_rule1 do
    learning_enrollment_ids =
      WorkflowRun
      |> Ash.Query.filter(definition.type == :learning)
      |> Ash.read!(authorize?: false)
      |> Enum.map(fn run -> run.input_snapshot["enrollment_id"] end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enrollment
    |> Ash.Query.filter(status == :confirmed)
    |> Ash.read!(authorize?: false)
    |> Enum.reject(fn enrollment ->
      MapSet.member?(learning_enrollment_ids, enrollment.id)
    end)
    |> Enum.map(fn enrollment ->
      %{
        entity_type: :enrollment,
        entity_id: enrollment.id,
        workspace_id: enrollment.workspace_id,
        detail: %{
          event_id: enrollment.event_id,
          course_id: enrollment.course_id,
          user_id: enrollment.user_id
        }
      }
    end)
  end

  # ── 规2：pending 无 approval_deadline（四资源 UNION）------------------------

  defp scan_rule2 do
    Enum.flat_map(@pending_deadline_specs, fn {resource, entity_type} ->
      resource
      |> Ash.Query.filter(status == :pending and is_nil(approval_deadline))
      |> Ash.read!(authorize?: false)
      |> Enum.map(fn record ->
        %{
          entity_type: entity_type,
          entity_id: record.id,
          # WorkspaceApplication 无 workspace_id 列（目标工作台尚不存在）→ nil
          workspace_id: Map.get(record, :workspace_id),
          detail: %{}
        }
      end)
    end)
  end

  # ── 规3：active sponsorship 的 sponsorship.active 发布 job 处于 discarded ----

  defp scan_rule3 do
    sponsorship_ids =
      discarded_signal_jobs(@active_signal)
      |> Enum.flat_map(fn job ->
        case job.args["data"]["idempotency_key"] do
          @active_signal <> ":" <> id -> [id]
          _ -> []
        end
      end)
      |> Enum.uniq()

    if sponsorship_ids == [] do
      []
    else
      Sponsorship
      |> Ash.Query.filter(status == :active and id in ^sponsorship_ids)
      |> Ash.read!(authorize?: false)
      |> Enum.map(fn sponsorship ->
        %{
          entity_type: :sponsorship,
          entity_id: sponsorship.id,
          workspace_id: sponsorship.workspace_id,
          detail: %{
            sponsor_user_id: sponsorship.sponsor_user_id,
            level: to_string(sponsorship.level)
          }
        }
      end)
    end
  end

  # ── 规4:open 实体无 published 教研定义(Event=:curriculum 定义;Course=
  # :course_preparation 定义,S6 起教研流程类型分家;Course 侧含 draft——
  # 教研发生在 draft→launch 之间,缺定义的断流课程在 draft 期就该看见,
  # 不等 open 才暴露) ──

  defp scan_rule4 do
    curriculum_workspace_ids =
      WorkflowDefinition
      |> Ash.Query.filter(type == :curriculum and status == :published)
      |> Ash.read!(authorize?: false)
      |> MapSet.new(fn definition -> definition.workspace_id end)

    prep_workspace_ids =
      WorkflowDefinition
      |> Ash.Query.filter(type == :course_preparation and status == :published)
      |> Ash.read!(authorize?: false)
      |> MapSet.new(fn definition -> definition.workspace_id end)

    # S6:course 侧教研流程 = course_preparation prep run(Curriculum.PrepInstantiator)
    # ——draft/open 课程的孤儿判定改为「工作台无 published course_preparation
    # 定义」(无条件命中;prep run 缺失 = 教研流程不会实例化)。course 扩 draft:
    # 教研发生在 draft→launch 之间,缺定义工作台的 draft 课程教研链已断流,
    # 不等 open 才暴露(UAT P2:tutor 的 draft 课撞 :course_preparation_
    # definition_not_found,旧口径扫不到)。Event 保留 curriculum_enabled
    # 开关过滤(false 合法不命中,退出通道),定义仍取 :curriculum 型。
    # 「教研已完成」口径与 Instantiator 收窄对齐:course.launched 不再实例化
    # :curriculum run,open 课程不因缺教研 run 命中(命中条件只有定义缺失)。
    orphans =
      open_entities(Event)
      |> Enum.reject(fn entity ->
        MapSet.member?(curriculum_workspace_ids, entity.workspace_id)
      end)
      |> Kernel.++(
        draft_or_open_unconditional(Course)
        |> Enum.reject(fn entity ->
          MapSet.member?(prep_workspace_ids, entity.workspace_id)
        end)
      )

    Enum.map(orphans, fn entity ->
      entity_type = if is_struct(entity, Event), do: :event, else: :course

      %{
        entity_type: entity_type,
        entity_id: entity.id,
        workspace_id: entity.workspace_id,
        detail: %{title: entity.title}
      }
    end)
  end

  defp open_entities(resource) do
    resource
    |> Ash.Query.filter(status == :open and curriculum_enabled)
    |> Ash.read!(authorize?: false)
  end

  defp draft_or_open_unconditional(resource) do
    resource
    |> Ash.Query.filter(status in [:draft, :open])
    |> Ash.read!(authorize?: false)
  end

  # ── 规5：closed/cancelled Event 仍有非终态 curriculum run ---------------------
  # S6 起 event-only：course 侧 :curriculum run 不再创建（教研由
  # course_preparation prep run 承担，Instantiator 已收窄），存量 dev 行自然
  # aging，不再纳入本规则扫描。

  defp scan_rule5 do
    closed_keys = closed_entity_keys(Event)

    if map_size(closed_keys) == 0 do
      []
    else
      WorkflowRun
      |> Ash.Query.filter(definition.type == :curriculum and status in @non_terminal_statuses)
      |> Ash.read!(authorize?: false)
      |> Enum.flat_map(fn run ->
        case Map.get(closed_keys, run.input_snapshot["key"]) do
          nil ->
            []

          {entity_type, workspace_id} ->
            [_prefix, entity_id] = String.split(run.input_snapshot["key"], "_", parts: 2)

            [
              %{
                entity_type: entity_type,
                entity_id: entity_id,
                workspace_id: workspace_id,
                detail: %{run_id: run.id, status: to_string(run.status)}
              }
            ]
        end
      end)
    end
  end

  defp closed_entity_keys(resource) do
    entity_type = if resource == Event, do: :event, else: :course
    prefix = to_string(entity_type)

    resource
    |> Ash.Query.filter(status in [:closed, :cancelled])
    |> Ash.read!(authorize?: false)
    |> Map.new(fn entity ->
      {"#{prefix}_#{entity.id}", {entity_type, entity.workspace_id}}
    end)
  end

  # ── 规6：信号族死信（7 天窗口内）--------------------------------------------

  defp scan_rule6 do
    cutoff =
      DateTime.add(DateTime.utc_now(), -@dead_letter_window_days * 86_400, :second)

    dead_letter_jobs(cutoff)
    |> Enum.map(fn job ->
      %{
        entity_type: :oban_job,
        entity_id: to_string(job.id),
        workspace_id: nil,
        detail: %{
          worker: job.worker,
          signal_type: job.args["signal_type"],
          error: last_error(job.errors)
        }
      }
    end)
  end

  # oban_jobs 包读助手（规3/6）：postgrex 自动解码 jsonb，job 为 %{id, worker,
  # args, errors} 结构体化行。测试环境可直接 SQL 造 discarded 行（同
  # notification_fanout_test 先例）。
  defp dead_letter_jobs(cutoff) do
    placeholders =
      @dead_letter_workers |> Enum.with_index(1) |> Enum.map_join(", ", fn {_, i} -> "$#{i}" end)

    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT id, worker, args, errors
        FROM oban_jobs
        WHERE state = 'discarded'
          AND worker IN (#{placeholders})
          AND inserted_at >= $#{length(@dead_letter_workers) + 1}
        """,
        @dead_letter_workers ++ [cutoff]
      )

    Enum.map(rows, fn [id, worker, args, errors] ->
      %{id: id, worker: worker, args: args, errors: errors}
    end)
  end

  defp discarded_signal_jobs(signal_type) do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT id, worker, args, errors
        FROM oban_jobs
        WHERE state = 'discarded'
          AND worker = $1
          AND args->>'signal_type' = $2
        """,
        ["Cgc2046.Workflows.SignalPublishWorker", signal_type]
      )

    Enum.map(rows, fn [id, worker, args, errors] ->
      %{id: id, worker: worker, args: args, errors: errors}
    end)
  end

  defp last_error(errors) when is_list(errors) and errors != [] do
    errors |> List.last() |> Map.get("error")
  end

  defp last_error(_errors), do: nil

  # ── 规7：learning run 停滞（与 LPW 提醒同源判定）-----------------------------

  # S8（ADR-0011/R50）：停滞口径 = Runs.stagnant?/2 单源——活动时间 = 最新
  # attempt created_at，零 attempt 回退 run inserted_at；阈值单点定义在
  # Learning.Runs，只引用。detail 键 last_activity_at（原 last_update_at）。
  defp scan_rule7 do
    now = DateTime.utc_now()

    WorkflowRun
    |> Ash.Query.filter(status == :running and definition.type == :learning)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&Cgc2046.Learning.Runs.stagnant?(&1, now))
    |> Enum.map(&stagnation_candidate/1)
  end

  defp stagnation_candidate(run) do
    input = run.input_snapshot || %{}
    enrollment_id = Map.get(input, "enrollment_id") || Map.get(input, :enrollment_id)

    %{
      entity_type: :workflow_run,
      entity_id: run.id,
      workspace_id: run.workspace_id,
      detail: %{
        enrollment_id: enrollment_id,
        title: Map.get(input, "title") || Map.get(input, :title),
        last_activity_at: DateTime.to_iso8601(Cgc2046.Learning.Runs.last_activity_at(run))
      }
    }
  end

  # ── 规8-12：名额账本 / 展示投影 / 缓存漂移（ADR-0009 PR⑤ U7；R17；KD2；Fable 5 HIGH-1）
  #
  # 五条均经 Repo 直查（账本写路径全裸 SQL 不经 Ash action，对账读同口径；
  # 规3/6 的 oban_jobs 包读先例）。entity_type 复用 :event/:course，/admin
  # 对账页按既有投影实体链接渲染。Repo.query 返回的 uuid 列为 16 字节
  # 原始二进制，落 Finding 前一律 Ecto.UUID.load! 转字符串（Oban JSON 载荷同限）。

  # 规8：open offering 无账本行（launched 信号建行 + 报名懒建双路均未到达）。
  # 信号在途窗口（秒级）命中的瞬时 finding 下一拍自消（刷新语义兜底）。
  defp scan_rule8 do
    {:ok, %{rows: rows}} =
      Repo.query("""
      SELECT 'event' AS kind, e.id, e.workspace_id, e.title
      FROM events e
      WHERE e.status = 'open'
        AND NOT EXISTS (
          SELECT 1 FROM admission_capacity_ledgers l
          WHERE l.offering_kind = 'event' AND l.offering_id = e.id
        )
      UNION ALL
      SELECT 'course', c.id, c.workspace_id, c.title
      FROM courses c
      WHERE c.status = 'open'
        AND NOT EXISTS (
          SELECT 1 FROM admission_capacity_ledgers l
          WHERE l.offering_kind = 'course' AND l.offering_id = c.id
        )
      """)

    Enum.map(rows, fn [kind, offering_id, workspace_id, title] ->
      %{
        entity_type: String.to_atom(kind),
        entity_id: Ecto.UUID.load!(offering_id),
        workspace_id: Ecto.UUID.load!(workspace_id),
        detail: %{title: title}
      }
    end)
  end

  # 规9：账本 occupancy ≠ 占位报名计数（占位态 = confirmed + payment_pending，
  # 与 Enrollment 占位/释放路径口径一致：payment_pending 已占位待付）。
  defp scan_rule9 do
    {:ok, %{rows: rows}} =
      Repo.query("""
      WITH occupying AS (
        SELECT 'event' AS kind, event_id AS offering_id, COUNT(*)::bigint AS n
        FROM enrollments
        WHERE status IN ('confirmed', 'payment_pending') AND event_id IS NOT NULL
        GROUP BY event_id
        UNION ALL
        SELECT 'course', course_id, COUNT(*)::bigint
        FROM enrollments
        WHERE status IN ('confirmed', 'payment_pending') AND course_id IS NOT NULL
        GROUP BY course_id
      )
      SELECT l.offering_kind, l.offering_id, l.workspace_id, l.occupancy,
             COALESCE(o.n, 0) AS enrollment_count
      FROM admission_capacity_ledgers l
      LEFT JOIN occupying o ON o.kind = l.offering_kind AND o.offering_id = l.offering_id
      WHERE l.occupancy <> COALESCE(o.n, 0)
      """)

    Enum.map(rows, fn [kind, offering_id, workspace_id, occupancy, enrollment_count] ->
      %{
        entity_type: String.to_atom(kind),
        entity_id: Ecto.UUID.load!(offering_id),
        workspace_id: Ecto.UUID.load!(workspace_id),
        detail: %{occupancy: occupancy, enrollment_count: enrollment_count}
      }
    end)
  end

  # 规10：展示投影漂移超一拍（R17「超 N 拍」= 与 cron 周期对齐的一拍宽限）——
  # 投影（confirmed_count / confirmed_count_sync_version）与账本不一致，且账本
  # 最近变更早于一个扫描周期（capacity.synced 异步在途的正常窗口不告警；
  # 超窗仍漂移 = 信号丢失/订阅方失败）。
  defp scan_rule10 do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT l.offering_kind, l.offering_id, l.workspace_id, l.occupancy,
               l.sync_version, e.confirmed_count, e.confirmed_count_sync_version
        FROM admission_capacity_ledgers l
        JOIN events e ON e.id = l.offering_id
        WHERE l.offering_kind = 'event'
          AND (e.confirmed_count <> l.occupancy
               OR e.confirmed_count_sync_version <> l.sync_version)
          AND l.updated_at < NOW() - ($1 * INTERVAL '1 second')
        UNION ALL
        SELECT l.offering_kind, l.offering_id, l.workspace_id, l.occupancy,
               l.sync_version, c.confirmed_count, c.confirmed_count_sync_version
        FROM admission_capacity_ledgers l
        JOIN courses c ON c.id = l.offering_id
        WHERE l.offering_kind = 'course'
          AND (c.confirmed_count <> l.occupancy
               OR c.confirmed_count_sync_version <> l.sync_version)
          AND l.updated_at < NOW() - ($1 * INTERVAL '1 second')
        """,
        [@drift_grace_seconds]
      )

    Enum.map(rows, fn [
                        kind,
                        offering_id,
                        workspace_id,
                        occupancy,
                        sync_version,
                        confirmed_count,
                        applied_version
                      ] ->
      %{
        entity_type: String.to_atom(kind),
        entity_id: Ecto.UUID.load!(offering_id),
        workspace_id: Ecto.UUID.load!(workspace_id),
        detail: %{
          occupancy: occupancy,
          sync_version: sync_version,
          confirmed_count: confirmed_count,
          confirmed_count_sync_version: applied_version
        }
      }
    end)
  end

  # 规11：occupancy > capacity（R16/AE4：capacity 调小低于 occupancy 放行后的
  # 合法超员窗口由本规则看护，存量占位自然释放收敛后 finding 自消）。
  defp scan_rule11 do
    {:ok, %{rows: rows}} =
      Repo.query("""
      SELECT offering_kind, offering_id, workspace_id, occupancy, capacity
      FROM admission_capacity_ledgers
      WHERE capacity IS NOT NULL AND occupancy > capacity
      """)

    Enum.map(rows, fn [kind, offering_id, workspace_id, occupancy, capacity] ->
      %{
        entity_type: String.to_atom(kind),
        entity_id: Ecto.UUID.load!(offering_id),
        workspace_id: Ecto.UUID.load!(workspace_id),
        detail: %{occupancy: occupancy, capacity: capacity}
      }
    end)
  end

  # 规12：账本三列缓存漂移于 offering 真值（ADR-0009 Fable 5 HIGH-1）——
  # status / capacity / registration_deadline 经 launched / offering.capacity_changed
  # / *.ended 信号异步覆盖写（KTD4/KTD5），丢投不重试窗口内缓存滞留旧值；规8-11
  # 只看护 occupancy 与下游投影，本规则补「缓存≈真值」新不变量的上游看护。
  # 无宽限（Fable 5 复审 MEDIUM 缝隙修复）：旧版锚 l.updated_at < NOW()-600s 会被
  # reserve/release 的 SET updated_at=NOW()（不占缓存列、不收敛漂移）持续刷新——
  # 报名活跃的 offering 宽限永不满足、永不告警，恰是超卖风险最高者。改为「缓存≠
  # 真值即出 finding」：信号在途（秒级）命中的瞬时 finding 由刷新语义（逐规则
  # upsert + 未命中删除）下一拍自消（规8 同款先例），误报窗口低、无害、自愈。
  defp scan_rule12 do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT l.offering_kind, l.offering_id, l.workspace_id,
               l.status, e.status,
               l.capacity, e.capacity,
               l.registration_deadline, e.registration_deadline
        FROM admission_capacity_ledgers l
        JOIN events e ON e.id = l.offering_id
        WHERE l.offering_kind = 'event'
          AND (l.status <> e.status
               OR l.capacity IS DISTINCT FROM e.capacity
               OR l.registration_deadline IS DISTINCT FROM e.registration_deadline)
        UNION ALL
        SELECT l.offering_kind, l.offering_id, l.workspace_id,
               l.status, c.status,
               l.capacity, c.capacity,
               l.registration_deadline, c.registration_deadline
        FROM admission_capacity_ledgers l
        JOIN courses c ON c.id = l.offering_id
        WHERE l.offering_kind = 'course'
          AND (l.status <> c.status
               OR l.capacity IS DISTINCT FROM c.capacity
               OR l.registration_deadline IS DISTINCT FROM c.registration_deadline)
        """,
        []
      )

    Enum.map(rows, fn [
                        kind,
                        offering_id,
                        workspace_id,
                        ledger_status,
                        truth_status,
                        ledger_capacity,
                        truth_capacity,
                        ledger_deadline,
                        truth_deadline
                      ] ->
      %{
        entity_type: String.to_atom(kind),
        entity_id: Ecto.UUID.load!(offering_id),
        workspace_id: Ecto.UUID.load!(workspace_id),
        detail: %{
          drifts:
            cache_drifts(
              status: {ledger_status, truth_status},
              capacity: {ledger_capacity, truth_capacity},
              registration_deadline: {ledger_deadline, truth_deadline}
            )
        }
      }
    end)
  end

  # 规12 detail：仅列漂移字段，逐字段双值（ledger 缓存值 / truth offering 真值）。
  # registration_deadline 裸 SQL 解出 NaiveDateTime（无时区，order.ex 同款注释），
  # 落 jsonb 前转 ISO8601 字符串（规7 last_activity_at 同款）。
  defp cache_drifts(pairs) do
    pairs
    |> Enum.reject(fn {_field, {ledger, truth}} -> ledger == truth end)
    |> Map.new(fn {field, {ledger, truth}} ->
      {Atom.to_string(field), %{"ledger" => drift_value(ledger), "truth" => drift_value(truth)}}
    end)
  end

  defp drift_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp drift_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp drift_value(value), do: value
end
