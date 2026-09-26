defmodule Cgc2046.Mcp.Tools.ApprovePrep do
  @moduledoc """
  审核通过并发布课程（role-agent-journeys-v2 S5，R28，reviewer-per-policy
  或 Owner/Admin，确认流 two-tool 写，D-D3）。

  前置 prep_state == review。审核人 = 策略快照指定的 reviewer_user_id（未指定时
  任何工作台成员可审，允许 tutor 自审）或 Owner/Admin。通过 → 发布：生成不可变的新
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
    审核通过并发布课程，只在课程的教研流程处于 review 时可用。审核人是教研策略指定的 reviewer（未指定
    时任何工作台成员都可审，允许 tutor 自审），或 Owner/Admin。通过后生成一个不可变的新课程版本并发布：
    课程还是 draft 时变为 open（visibility=public 才会出现在公开面开放报名，仅 workspace 可见的只对成员
    开放），已 open 的课程切换到新版本；教研流程进入 published。确认与当前草稿版本
    绑定：确认前草稿被改动，本次确认失效，需要对新草稿重新审核。
    走确认流：第一次调用只返回 needs_confirmation + pending_id + summary，
    用户确认后调 confirm_operation(pending_id) 才执行。
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

  # reviewer-per-policy（快照指定 reviewer 则仅本人，否则任何成员，允许自审）
  # 或 Owner/Admin（R28）。§B#7：本函数自包含成员资格判定（Prep.reviewer?/2 在
  # 未指定 reviewer 时恒 true——成员门槛第一段由 Wrapper member 门保证，但确认
  # 段不走 Wrapper），两段共用：确认窗口内被移出工作台的角色在 confirm 段兜底拒绝。
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
