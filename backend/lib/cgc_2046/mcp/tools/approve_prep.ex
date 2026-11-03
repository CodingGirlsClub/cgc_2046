defmodule Cgc2046.Mcp.Tools.ApprovePrep do
  @moduledoc """
  审核通过并发布课程（role-agent-journeys-v2 S5，R28，reviewer-per-policy
  或 Owner/Admin，确认流 two-tool 写，D-D3）。

  前置 prep_state == review。审核人 = 策略快照指定的 reviewer_user_id（未指定时
  被指派的 tutor 可审，允许自审）或 Owner/Admin。通过 → 发布：生成不可变的新
  CourseRevision（draft 课程随之 launch 开放报名；已 open 的课程换绑新版本），
  prep_state → published，run 转 succeeded。

  确认流依据：发布是公开面副作用（课程公开报名开启）。

  **审批绑定草稿版本（P2 安全修复）**：第一段建 pending 时把当前草稿版本
  （Output.version）固化进 pending params 并写进 summary；confirm 段经
  `Prep.approve/3` 在发布事务内核验——确认窗内 tutor 改写草稿（版本 +1）→
  旧确认整体回滚失效，须对新草稿重新审核，杜绝「审 v1 发 v2」。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.Prep
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    Approve and publish a course whose preparation is in review. Available to workspace owners/admins
    or the designated reviewer; when no reviewer is designated, only the assigned tutor may review.
    Self-review is allowed. Publishing creates an immutable course revision and opens a draft course,
    or updates the revision of an open course. Approval is bound to the current draft version; changes
    before confirmation require a new approval. The first call returns needs_confirmation, pending_id
    and summary. Call confirm_operation only after the user confirms.
    """
  end

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:course_id, {:required, :string}, description: "课程 ID（UUID）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "approve_prep", fn actor, workspace_id, params ->
        course_id = params["course_id"]

        with {:ok, course} <- Course.fetch_scoped(workspace_id, course_id),
             {:ok, run} <- fetch_run(course),
             :ok <- authorize(actor, workspace_id, run),
             :ok <- require_review(run) do
          # 绑定审核时点草稿版本（P2）：固化进 pending params，confirm 段
          # 发布事务内核验——确认窗内草稿被改则旧确认失效
          draft_version = Prep.draft_version(course)

          summary =
            "审核通过并发布课程「#{course.title}」（#{course.id}）：draft → open，" <>
              "发布后课程公开报名开启（绑定草稿版本 v#{draft_version}；草稿变更后需重新审核）"

          Confirmation.request(
            frame.assigns[:current_user],
            "approve_prep",
            Map.put(params, "draft_version", draft_version),
            summary
          )
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @doc """
  确认后真正执行（由 `Confirmation.execute/3` 直接分派调用）。
  """
  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    workspace_id = params["workspace_id"]
    course_id = params["course_id"]

    with {:ok, course} <- Course.fetch_scoped(workspace_id, course_id),
         {:ok, run} <- fetch_run(course),
         :ok <- authorize(actor, workspace_id, run),
         # 绑定的审核草稿版本随 pending params 传入（第一段固化）；版本核验
         # 在发布事务内完成（Prep.approve/3 → publish 的 require_reviewed_draft）
         {:ok, updated} <- Prep.approve(run, actor, params["draft_version"]) do
      {:ok,
       %{
         course_id: course.id,
         prep_state: Prep.prep_state(updated),
         course_status: "open"
       }}
    end
  end

  # 两段共用成员资格与当前 reviewer 判定，确认窗口内撤权或改派立即生效。
  defp authorize(actor, workspace_id, run) do
    if Cgc2046.Accounts.MembershipContext.membership_of(actor, workspace_id) &&
         (Prep.reviewer?(run, actor) or Prep.manage?(actor, workspace_id)) do
      :ok
    else
      {:error, "forbidden: reviewer-per-policy, owner or admin required to approve prep"}
    end
  end

  # 第一段快速失败省 pending；confirm 段由 authorize 重查 + Prep.approve 前置断言兜底
  defp require_review(run) do
    if Prep.prep_state(run) == "review" do
      :ok
    else
      {:error, "prep is not awaiting review (prep_state=#{Prep.prep_state(run)})"}
    end
  end

  defp fetch_run(course) do
    case Prep.fetch_run(course.id, course.workspace_id) do
      nil -> {:error, "no preparation run found for course #{course.id}"}
      run -> {:ok, run}
    end
  end
end
