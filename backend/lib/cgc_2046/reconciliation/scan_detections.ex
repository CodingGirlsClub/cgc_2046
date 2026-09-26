defmodule Cgc2046.Reconciliation.ScanDetections do
  # 对账扫描检测函数库（#852 C9 拆分，E-10 实体/信号/停滞域，规1-7）。
  # ReconciliationScanWorker 每拍经 rules/0 分发表逐规则调用 detect_*/0，
  # 返回 candidates 交 Finding.apply_rule/3（D2 刷新语义单源）。
  # 规则语义清单见 RulesRegistry（单源）。

  require Ash.Query

  alias Cgc2046.Accounts.JoinRequest
  alias Cgc2046.Accounts.WorkspaceApplication
  alias Cgc2046.Courses.Course
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Events.Event
  alias Cgc2046.Sponsorship.Sponsorship
  alias Cgc2046.Repo
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun

  # 规3/6 判定的 worker 白名单（NotificationWorker 含提醒/审批结果全部通知）。
  # 押金 no-show 结算（KTD7）同列：其死信 = 连续三拍结算硬失败，虽由下一拍 cron
  # 自愈，但资金终态滞留窗口必须在 /admin 对账页可见（不静默）。
  # 退款（#862）同列：重试耗尽被丢弃的退款任务此前完全不可见——它同时是规17
  # 「refunding 无在途任务」的成因面，死信行（Pruner 7 天窗口内）须可见。
  @dead_letter_workers [
    "Cgc2046.Workflows.SignalPublishWorker",
    "Cgc2046.Notifications.NotificationWorker",
    "Cgc2046.Notifications.Workers.DeliveryWorker",
    "Cgc2046.Payments.Workers.DepositForfeitWorker",
    "Cgc2046.Payments.Workers.PaymentRefundWorker"
  ]

  # 白名单只读访问器（ADR-0010 W1):worker 改名后字符串易漂移,测试经本函数
  # 断言「每个白名单模块真实存在」,杜绝「字符串漂移→规6 失明」形状复发。
  @doc false
  def dead_letter_workers, do: @dead_letter_workers

  # 规6 死信窗口：与 Oban Pruner max_age（7 天，config.exs）对齐
  @dead_letter_window_days 7

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

  # ── 规1：confirmed enrollment 无 learning run -------------------------------
  # issue #505 D8 口径：run 归属判定 = user × 锚点 revision（双通道报名汇入
  # 同一 run——锚定的活动报名与课程报名共享一个 run，逐 enrollment 判定会
  # 误报汇入方）。无锚报名（事件型 run）仍按 enrollment 锚判定。
  # revision 换版后旧 run 锚旧版 → 新锚无 run 命中本规则（published 信号
  # 补种路径的对账兜底，1i）。

  def detect_confirmed_enrollment_without_run do
    learning_runs =
      WorkflowRun
      |> Ash.Query.filter(definition.type == :learning)
      |> Ash.read!(authorize?: false)

    run_pairs =
      MapSet.new(learning_runs, fn run ->
        {run.subject_user_id, run.subject_course_revision_id}
      end)

    run_enrollment_ids = MapSet.new(learning_runs, & &1.subject_enrollment_id)

    Enrollment
    |> Ash.Query.filter(status == :confirmed)
    |> Ash.read!(authorize?: false)
    |> with_anchor_revisions()
    |> Enum.reject(fn
      # 课程未发布（无锚 course 报名）：K4 不种 run 是设计决策，发布后 1i
      # 补种自愈——未发布窗口期不是对账异常（review 建议 2）。
      {_enrollment, :unpublished} ->
        true

      {enrollment, anchor_revision_id} ->
        if anchor_revision_id do
          MapSet.member?(run_pairs, {enrollment.user_id, anchor_revision_id})
        else
          MapSet.member?(run_enrollment_ids, enrollment.id)
        end
    end)
    |> Enum.map(fn {enrollment, _anchor} ->
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

  # 报名锚点 revision 批量解析（D1 配套课索引口径）：course 报名锚 =
  # Course.current_revision_id；event 报名锚 = events.course_revision_id。
  # 无锚 → nil（事件型 run 维度）。资源均 global?(true)，跨租户直读。
  defp with_anchor_revisions(enrollments) do
    course_ids = enrollments |> Enum.map(& &1.course_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    event_ids = enrollments |> Enum.map(& &1.event_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    course_anchors =
      Course
      |> Ash.Query.filter(id in ^course_ids)
      |> Ash.Query.select([:id, :current_revision_id])
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.id, &1.current_revision_id})

    event_anchors =
      Event
      |> Ash.Query.filter(id in ^event_ids)
      |> Ash.Query.select([:id, :course_revision_id])
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.id, &1.course_revision_id})

    Enum.map(enrollments, fn enrollment ->
      anchor =
        cond do
          enrollment.course_id ->
            # nil = 课程未发布（区别于「无锚 event 报名」），规1 排除该中间态。
            Map.get(course_anchors, enrollment.course_id) || :unpublished

          enrollment.event_id ->
            Map.get(event_anchors, enrollment.event_id)
        end

      {enrollment, anchor}
    end)
  end

  # ── 规2：pending 无 approval_deadline（四资源 UNION）------------------------

  def detect_pending_without_deadline do
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

  def detect_active_sponsorship_signal_dead do
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

  def detect_open_entity_without_research_definition do
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

  def detect_nonterminal_research_run_for_closed_entity do
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

  def detect_dead_letter_job do
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
  def detect_learning_run_stalled do
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

  # ── 规17：refunding 订单无在途退款 job（#862）--------------------------------

  # C2（#845）把「进 refunding 即同事务恰好入队一次」收进 Order action 后，
  # 「refunding 而队列无在途任务」只剩任务侧被人工删除 / 重试耗尽丢弃等极端
  # 运维场景（丢弃行可见性由规 6 死信白名单补，本规则看在途缺失本身）。
  # 在途 state 口径 = Oban :incomplete 的 Postgres 子集（job.ex
  # unique_states(:incomplete) 还含 suspended，但那是隔离引擎语义，生产
  # Postgres 引擎不产生）：available / scheduled / executing / retryable。
  # 15 分钟宽限纯防御——同事务入队下理论零宽限即可。
  @refund_grace_minutes 15
  @refund_inflight_job_states ~w(available scheduled executing retryable)
  @refund_worker "Cgc2046.Payments.Workers.PaymentRefundWorker"

  # 白名单只读访问器（ADR-0010 W1 同 dead_letter_workers/0）：worker 改名后
  # 字符串易漂移，测试经本函数断言与真实模块一致，杜绝「字符串漂移→规 17 失明」。
  @doc false
  def refund_worker, do: @refund_worker

  def detect_refunding_without_refund_job do
    cutoff = DateTime.add(DateTime.utc_now(), -@refund_grace_minutes * 60, :second)

    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT o.id::text, o.workspace_id::text
        FROM payments_orders o
        WHERE o.status = 'refunding'
          AND o.updated_at < $3
          AND NOT EXISTS (
            SELECT 1
            FROM oban_jobs j
            WHERE j.worker = $1
              AND j.args->>'order_id' = o.id::text
              AND j.state = ANY($2)
          )
        """,
        [@refund_worker, @refund_inflight_job_states, cutoff]
      )

    Enum.map(rows, fn [order_id, workspace_id] ->
      %{
        entity_type: :payment_order,
        entity_id: order_id,
        workspace_id: workspace_id,
        detail: %{
          status: "refunding",
          hint: "订单停在 refunding 且队列无在途退款任务，可用 retry_refund 重入退款链"
        }
      }
    end)
  end
end
