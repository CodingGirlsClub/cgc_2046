defmodule Cgc2046.Workers.ReconciliationScanWorker do
  @moduledoc """
  对账扫描 worker（E-10 #125；设计 docs/plans/2026-08-15-011-e10-reconciliation-scan.md D2）。

  Oban cron 每 10 分钟一拍（config.exs crontab 第 5 项），扫六条孤儿规则 →
  落 `reconciliation_findings`（`Cgc2046.Reconciliation.Finding`）。

  ## 六规则（rule 枚举见 Finding moduledoc）

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
  4. `:open_entity_without_research_definition` — open 且 research_enabled 的
     Event/Course 其工作台无 published 教研定义（research_enabled=false 合法不命中）
  5. `:nonterminal_research_run_for_closed_entity` — closed/cancelled Event/Course
     仍有非终态教研 run（instance key `event_<id>`/`course_<id>`，reaper 同约定；
     ResearchInstantiator 二次校验与 INSERT 竞态 / reaper cancel 失败残余窗口兜底）
  6. `:dead_letter_job` — 信号族死信（SignalPublishWorker / NotificationWorker）。
     **Pruner 7 天窗口内判定**：oban_jobs 超出 Pruner max_age（7 天）的 discarded
     历史行不报告——死信告警只覆盖可排查窗口，历史已过期行交给 Pruner 清理。

  ## 刷新语义（D2）

  逐规则：命中 upsert（唯一键 (rule, entity_type, entity_id)——已存在走 :refresh
  保 first_seen_at、刷新 last_seen_at，不存在走 :create 双时间戳 = now）；本次未命中
  的行删除。**「无孤儿 → 空报告」由结构保证**：孤儿消解后下一拍即删。

  ## 平台读（specs/unique 同款：approval_expiry_worker）

  规1/2/4/5 走 Ash 查询下推（`authorize?: false` 跨租户全局读）；规3/6 经 Repo
  直查 oban_jobs（包读助手）。Finding 写同样 `authorize?: false`——资源 policy 仅
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
  alias Cgc2046.Events.Course
  alias Cgc2046.Events.Enrollment
  alias Cgc2046.Events.Event
  alias Cgc2046.Events.Sponsorship
  alias Cgc2046.Reconciliation.Finding
  alias Cgc2046.Repo
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun

  # 规3/6 判定的信号族 worker 白名单（NotificationWorker 含提醒/审批结果全部通知）
  @dead_letter_workers [
    "Cgc2046.Workers.SignalPublishWorker",
    "Cgc2046.Workers.NotificationWorker"
  ]

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

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Enum.each(rules(), fn {rule, scan} ->
      apply_rule(rule, scan.())
    end)

    :ok
  end

  # 六规则分派表（运行时求值：scan_ruleN 为私有函数，编译期前向引用不可行）
  defp rules do
    [
      {:confirmed_enrollment_without_run, fn -> scan_rule1() end},
      {:pending_without_deadline, fn -> scan_rule2() end},
      {:active_sponsorship_signal_dead, fn -> scan_rule3() end},
      {:open_entity_without_research_definition, fn -> scan_rule4() end},
      {:nonterminal_research_run_for_closed_entity, fn -> scan_rule5() end},
      {:dead_letter_job, fn -> scan_rule6() end}
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

  # ── 规4：open 且 research_enabled 但工作台无 published 教研定义 --------------

  defp scan_rule4 do
    research_workspace_ids =
      WorkflowDefinition
      |> Ash.Query.filter(type == :research and status == :published)
      |> Ash.read!(authorize?: false)
      |> MapSet.new(fn definition -> definition.workspace_id end)

    open_research_enabled(Event)
    |> Kernel.++(open_research_enabled(Course))
    |> Enum.reject(fn entity ->
      MapSet.member?(research_workspace_ids, entity.workspace_id)
    end)
    |> Enum.map(fn entity ->
      entity_type = if is_struct(entity, Event), do: :event, else: :course

      %{
        entity_type: entity_type,
        entity_id: entity.id,
        workspace_id: entity.workspace_id,
        detail: %{title: entity.title}
      }
    end)
  end

  defp open_research_enabled(resource) do
    resource
    |> Ash.Query.filter(status == :open and research_enabled)
    |> Ash.read!(authorize?: false)
  end

  # ── 规5：closed/cancelled Event/Course 仍有非终态 research run --------------

  defp scan_rule5 do
    closed_keys = closed_entity_keys(Event) |> Map.merge(closed_entity_keys(Course))

    if map_size(closed_keys) == 0 do
      []
    else
      WorkflowRun
      |> Ash.Query.filter(definition.type == :research and status in @non_terminal_statuses)
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
        ["Cgc2046.Workers.SignalPublishWorker", signal_type]
      )

    Enum.map(rows, fn [id, worker, args, errors] ->
      %{id: id, worker: worker, args: args, errors: errors}
    end)
  end

  defp last_error(errors) when is_list(errors) and errors != [] do
    errors |> List.last() |> Map.get("error")
  end

  defp last_error(_errors), do: nil
end
