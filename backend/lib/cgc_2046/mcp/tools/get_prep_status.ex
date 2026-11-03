defmodule Cgc2046.Mcp.Tools.GetPrepStatus do
  @moduledoc """
  读取课程教研流程状态（role-agent-journeys-v2 S5，R22-R28，读面）。

  工作台成员按课程领域可见性或当前教研 run 的审核授权读取。返回 prep_state /
  生效策略（override-first 合并后）/ 被指派的 tutor 摘要 / 最新质量报告 /
  实时计算的结构门禁违规清单（`gate_violations`）与软提示清单
  （`gate_warnings`，不阻断发布）/ run version（乐观锁版本，供并发对话）。

  S6 起 run 读取经 `Prep.ensure_active_run/2` 懒开新 run（读取即写：触发面 =
  本工具与 submit_prep_for_check）——发布后首读即开新一轮周期，自动有活动
  run 驱动下一版本（次周期 assignee 沿用）。#1128 起返回周期归因：`created_at` /
  `created_reason`（`course_created` | `next_cycle`）/ `created_by`（触发人摘要，
  首周期 null）/ `previous_run_id`（上一周期，首周期 null）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.User
  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.Prep
  alias Cgc2046.Mcp.Wrapper
  alias Cgc2046.Workflows.WorkflowRun

  require Ash.Query

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    Read preparation status for a course visible to the caller: prep_state, effective policy,
    assigned tutor, latest quality report, gate_violations, gate_warnings, run_id and version.
    Cycle attribution is included: created_at, created_reason (course_created = first cycle from
    the course.created signal / next_cycle = lazily opened after publication), created_by
    (triggering user; null for the first cycle) and previous_run_id (null for the first cycle).
    Draft courses require tutor/management access or review authorization for the course's active
    preparation run (designated reviewer, or current assignee when none is designated). Review
    authorization grants only this preparation-status projection. Reading a published course starts
    a new preparation cycle when needed, retaining the previous tutor assignment.
    """
  end

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:course_id, {:required, :string}, description: "课程 ID（UUID）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "get_prep_status", fn actor, workspace_id, params ->
        course_id = params["course_id"]

        with {:ok, course, run} <- fetch_preparation(workspace_id, course_id, actor) do
          gate = Prep.gate(course)
          assignee_id = Prep.assignee(run)

          {:ok,
           %{
             course_id: course.id,
             # 周期切换可辨（#1126）：发布后懒开的新 run 与旧 run 的 version 各自独立
             run_id: run.id,
             prep_state: Prep.prep_state(run),
             policy: Prep.policy(run),
             assignee_user_id: assignee_id,
             tutor: user_summary(assignee_id),
             latest_quality_report: (run.facts || %{})["latest_quality_report"],
             gate_violations: gate.violations,
             gate_warnings: gate.warnings,
             version: run.version,
             # #1128 归因：周期从哪来、谁触发、接的是哪一周期。
             # 首周期（course_created）的 created_by 为 nil（事件载荷无 actor）。
             created_at: run.inserted_at,
             created_reason: run.created_reason && to_string(run.created_reason),
             created_by: user_summary(run.created_by_actor_id),
             previous_run_id: run.previous_run_id
           }}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 审核例外只投影已校验的本台 active run，不二次查找或懒开新周期；
  # 否则授权检查后 run 恰好结束时，会读到未经授权的新 run 并产生创建 run 的副作用。
  defp fetch_preparation(workspace_id, course_id, actor) do
    case Course.fetch_scoped(workspace_id, course_id, actor: actor) do
      {:ok, course} ->
        # S6：具备课程领域读权的调用者保留发布后惰性开启下一周期的语义。
        with {:ok, run} <- Prep.ensure_active_run(course, actor: actor) do
          {:ok, course, run}
        end

      {:error, _message} = error ->
        with %WorkflowRun{} = run <- Prep.fetch_run(course_id, workspace_id),
             true <- Prep.reviewer?(run, actor),
             {:ok, %Course{status: :draft} = course} <-
               Course.fetch_scoped(workspace_id, course_id) do
          {:ok, course, run}
        else
          _ -> error
        end
    end
  end

  # 用户摘要（内部读 authorize?: false——行可见性已由 member 门保证，
  # 摘要只是同权限范围内的展示字段，PendingApprovals enrich 同款纪律）。
  # tutor（当前 assignee）与 created_by（#1128 归因）共用。
  defp user_summary(nil), do: nil

  defp user_summary(user_id) do
    case User |> Ash.Query.filter(id == ^user_id) |> Ash.read_one(authorize?: false) do
      {:ok, %User{} = user} -> %{user_id: user.id, display_name: user.display_name}
      _ -> %{user_id: user_id, display_name: nil}
    end
  end
end
