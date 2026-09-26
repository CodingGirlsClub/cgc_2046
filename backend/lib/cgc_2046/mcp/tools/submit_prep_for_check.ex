defmodule Cgc2046.Mcp.Tools.SubmitPrepForCheck do
  @moduledoc """
  提交课程教研质量检查（role-agent-journeys-v2 S5，R26，直接写）。

  前置 prep_state == authoring；同步跑结构门禁（Curriculum.PrepGate：标题非
  临时占位 / 内容存在 / goals 非空 / issues 非空 / Content 形状）：

  - 通过 → prep_state `quality_check`，记录 gate_passed_at 与检查的草稿版本；
  - 未过 → 保持 `authoring`，违规清单落 facts 并在响应中原样返回
    （`passed: false` + `violations`——业务结果非错误，逐条修复后重新提交）；
  - 响应另有 `warnings` 软提示清单（issue 未归属章节等）：不阻断流程，
    教材类课程应按提示补章节结构，无章节语义的课程可忽略。

  被指派的 tutor 或 Owner/Admin 可提交。

  S6 起 run 读取经 `Prep.ensure_active_run/2` 懒开新 run——发布后修订自动
  有活动 run 驱动下一版本（次周期 assignee 沿用）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.Prep
  alias Cgc2046.Mcp.Wrapper

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    直接写入，不走确认流：把课程教研内容提交结构检查，只在教研流程处于 authoring 时可用，被指派的 tutor
    或 Owner/Admin 可提交。检查项：标题不是临时标题、内容存在、goals 与 issues 不为空、内容形状合法。
    通过则进入 quality_check；未通过则保持 authoring，并返回 passed: false 与 violations（这是正常结果，
    不是错误，逐条修复后重新提交）。warnings 是不阻断的提示（如 issue 未归属章节），教材类课程应按提示
    补章节结构。
    """
  end

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:course_id, {:required, :string}, description: "课程 ID（UUID）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "submit_prep_for_check", fn actor, workspace_id, params ->
        course_id = params["course_id"]

        with {:ok, course} <- Course.fetch_scoped(workspace_id, course_id),
             {:ok, run} <- fetch_run(course, actor),
             :ok <- authorize(actor, workspace_id, run),
             {:ok, updated, gate} <- Prep.submit_for_check(run, actor) do
          {:ok,
           %{
             course_id: course.id,
             passed: gate.passed,
             prep_state: Prep.prep_state(updated),
             violations: gate.violations,
             warnings: gate.warnings,
             draft_version: gate.draft_version
           }}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 被指派的 tutor 或 Owner/Admin
  defp authorize(actor, workspace_id, run) do
    if Prep.assignee(run) == actor.id or Prep.manage?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: assigned tutor, owner or admin required to submit for quality check"}
    end
  end

  # S6：惰性 ensure_active_run——run 已终态（发布后次周期）时懒开新 run
  # （默认策略快照 + assignee 沿用，系统效应 authorize?: false）。
  defp fetch_run(course, actor) do
    Prep.ensure_active_run(course, actor: actor)
  end
end
