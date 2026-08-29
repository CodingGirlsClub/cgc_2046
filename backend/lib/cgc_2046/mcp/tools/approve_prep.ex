defmodule Cgc2046.Mcp.Tools.ApprovePrep do
  @moduledoc """
  审核通过并发布课程（role-agent-journeys-v2 S5，R28，reviewer-per-policy
  或 Owner/Admin，确认流 two-tool 写，D-D3）。

  前置 prep_state == review。审核人 = 策略快照指定的 reviewer_user_id（未指定时
  任何工作台成员可审，允许 tutor 自审）或 Owner/Admin。通过 → 发布（S5 切片语义
  = course launch：draft → open；S6 将改为生成不可变 CourseRevision），
  prep_state → published，run 转 succeeded。

  确认流依据：发布是公开面副作用（课程公开报名开启）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.Prep
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:course_id, {:required, :string}, description: "课程 ID（UUID）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "approve_prep", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]

        with {:ok, course} <- fetch_course(workspace_id, course_id),
             {:ok, run} <- fetch_run(course),
             :ok <- authorize(actor, workspace_id, run),
             :ok <- require_review(run) do
          summary =
            "审核通过并发布课程「#{course.title}」（#{course.id}）：draft → open，" <>
              "发布后课程公开报名开启"

          Confirmation.request(
            frame.assigns[:current_user],
            "approve_prep",
            params,
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

    with {:ok, course} <- fetch_course(workspace_id, course_id),
         {:ok, run} <- fetch_run(course),
         {:ok, updated} <- Prep.approve(run, actor) do
      {:ok,
       %{
         course_id: course.id,
         prep_state: Prep.prep_state(updated),
         course_status: "open"
       }}
    end
  end

  # reviewer-per-policy（快照指定 reviewer 则仅本人，否则任何成员，允许自审）
  # 或 Owner/Admin（R28）
  defp authorize(actor, workspace_id, run) do
    if Prep.reviewer?(run, actor) or Prep.manage?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: reviewer-per-policy, owner or admin required to approve prep"}
    end
  end

  # 第一段快速失败省 pending；confirm 段由 Prep.approve 前置断言兜底
  defp require_review(run) do
    if Prep.prep_state(run) == "review" do
      :ok
    else
      {:error, "prep is not awaiting review (prep_state=#{Prep.prep_state(run)})"}
    end
  end

  defp fetch_course(workspace_id, course_id) do
    case Course
         |> Ash.Query.for_read(:get_by_id, %{id: course_id})
         |> Ash.read_one(authorize?: false, tenant: workspace_id) do
      {:ok, nil} -> {:error, "course not found: #{course_id}"}
      {:ok, course} -> {:ok, course}
      {:error, _} -> {:error, "failed to load course"}
    end
  end

  defp fetch_run(course) do
    case Prep.fetch_run(course.id, course.workspace_id) do
      nil -> {:error, "no preparation run found for course #{course.id}"}
      run -> {:ok, run}
    end
  end
end
