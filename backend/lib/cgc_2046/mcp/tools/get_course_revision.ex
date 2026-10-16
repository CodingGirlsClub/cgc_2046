defmodule Cgc2046.Mcp.Tools.GetCourseRevision do
  @moduledoc """
  读取课程已发布版本（role-agent-journeys-v2 S6，R29/R38）。

  数据源 = `Cgc2046.Curriculum.CourseRevision`（发布即冻结的不可变快照），
  经 Curriculum 域读入口（`latest_revision/2` / `revision_by_number/3`）。
  `revision_number` 缺省 = 最新版本；显式指定按 (course_id, number) 取。
  响应是 content 快照的原样投影（goals + issues，objectives 嵌于 issue 内），
  不注入展示层 key——那是 get_course_content 草稿读面的职责。

  授权（`membership: :deferred`，工具层判定）：

  - workspace 成员（tutor/教研编辑/管理面）→ 任意版本；
  - 学员（`Learning.Authorization.authorize/3`：confirmed enrollment ∪ 活动挂载报名 ∪
    run 持有者，与网页 courseContent 同一范围）→ 最新 published 版本，以及本人任一
    learning run 绑定的版本。learner playbook 用 get_learning_state 的
    `run.revision_number` 取 rubric criterion id，run 绑旧版时它不是最新号；
  - 其他 → forbidden。

  从未发布过的课程返回「无已发布版本」明确错误（不回退草稿——草稿读面是
  get_course_content；公开 courseMap 的草稿回退与本工具无关）。
  """
  use Anubis.Server.Component, type: :tool, meta: %{membership: :deferred}

  require Ash.Query

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum
  alias Cgc2046.Learning.Authorization
  alias Cgc2046.Mcp.Wrapper
  alias Cgc2046.Workflows.WorkflowRun

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    读取课程的已发布版本（发布时冻结、不可修改）：goals 与 issues（学习目标嵌在各 issue 内）。
    revision_number 缺省为最新版本。工作台成员可读任意版本；学员（已确认报名本课程或其配套活动的人、
    学过这门课的人）可读最新版本，以及自己学习流程绑定的版本（get_learning_state 返回的
    run.revision_number）；其他版本与其他人返回 forbidden。课程从未发布时返回「无已发布版本」错误，
    不会退回读草稿（草稿用 get_course_content）。
    """
  end

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID(UUID)")
    field(:course_id, {:required, :string}, description: "课程 ID(UUID)")

    field(:revision_number, :integer, description: "版本号（≥1 整数；缺省 = 最新已发布版本）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "get_course_revision", fn actor, workspace_id, params ->
        course_id = params["course_id"]
        revision_number = params["revision_number"]

        with {:ok, course} <- Course.fetch_scoped(workspace_id, course_id),
             {:ok, latest} <- fetch_latest_revision(workspace_id, course.id),
             :ok <- authorize(actor, workspace_id, course.id, latest, revision_number),
             {:ok, revision} <-
               resolve_revision(workspace_id, course.id, latest, revision_number) do
          content = revision.content || %{}

          {:ok,
           %{
             course_id: course.id,
             revision_number: revision.number,
             published_at: DateTime.to_iso8601(revision.published_at),
             goals: content["goals"] || [],
             chapters: content["chapters"] || [],
             issues: content["issues"] || []
           }}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 授权三段：成员任意版本；学员读最新（缺省或显式等于最新号）或本人 run 绑定的版本；
  # 其余拒绝。latest 为 nil（从未发布）时学员只放行缺省读（随后报无版本）。
  defp authorize(actor, workspace_id, course_id, latest, revision_number) do
    cond do
      member?(actor, workspace_id) ->
        :ok

      Authorization.authorize(actor, workspace_id, course_id) != :ok ->
        {:error, "forbidden: workspace member or enrolled learner required"}

      revision_number == nil || (latest != nil && revision_number == latest.number) ->
        :ok

      own_run_revision?(actor, workspace_id, course_id, revision_number) ->
        :ok

      true ->
        {:error,
         "forbidden: learners can only read the latest published revision or the revision " <>
           "bound to their own learning run (run.revision_number from get_learning_state)"}
    end
  end

  # 本人任一 learning run 绑定该版本：subject 列直查，与 Runs.resumable_run/3 同款但不限状态
  # （同 learning_run_holder? 口径）。版本号不存在也返回 false 走 forbidden，不向学员区分「无此版本」
  defp own_run_revision?(actor, workspace_id, course_id, revision_number) do
    case Curriculum.revision_by_number(workspace_id, course_id, revision_number) do
      {:ok, %{id: revision_id}} ->
        WorkflowRun
        |> Ash.Query.filter(
          definition.type == :learning and subject_user_id == ^actor.id and
            subject_course_revision_id == ^revision_id
        )
        |> Ash.exists?(authorize?: false, tenant: workspace_id)

      _ ->
        false
    end
  end

  defp resolve_revision(_workspace_id, course_id, nil, nil),
    do: {:error, "no published revision for course #{course_id}"}

  defp resolve_revision(_workspace_id, _course_id, latest, nil), do: {:ok, latest}

  defp resolve_revision(workspace_id, course_id, _latest, revision_number) do
    case Curriculum.revision_by_number(workspace_id, course_id, revision_number) do
      {:ok, nil} -> {:error, "course revision #{revision_number} not found"}
      {:ok, revision} -> {:ok, revision}
      {:error, _} -> {:error, "failed to load course revision"}
    end
  end

  defp fetch_latest_revision(workspace_id, course_id) do
    case Curriculum.latest_revision(workspace_id, course_id) do
      {:ok, revision} -> {:ok, revision}
      {:error, _} -> {:error, "failed to load course revision"}
    end
  end

  defp member?(actor, workspace_id) do
    case MembershipContext.membership_of(actor, workspace_id) do
      nil -> false
      _membership -> true
    end
  end
end
