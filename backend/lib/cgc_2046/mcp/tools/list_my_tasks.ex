defmodule Cgc2046.Mcp.Tools.ListMyTasks do
  @moduledoc """
  读取 actor 在目标工作台的待办任务（role-agent-journeys-v2 S1/S5，
  R8/R20）。

  任务读面 = 两类聚合：

  1. `Cgc2046.PendingApprovals`（报名 / 加入申请 / 赞助三类 pending 行，
     已按 actor 的 owner/admin 成员资格在查询层预收窄），过滤到本工作台；
  2. 课程教研流程行（S5，R20）——本工作台非终态 prep run 按 actor 角色分派：
     - `course_prep_claimable`：prep_state draft 且未指派，actor 持 tutor 角色
       （或 owner/admin）→ 可认领；
     - `course_prep_authoring`：actor 是被指派 tutor 且 prep_state ∈
       (authoring, quality_check) → 待生产/修订内容与提交；
     - `course_prep_review`：prep_state == review 且 actor 是 reviewer-per-policy
       （快照指定 reviewer 则仅本人，否则任何成员；owner/admin 恒见）→ 待审核。

  member-only + workspace_id 必填（fail-closed 默认，无豁免 meta）；工作台按
  id 以 actor 授权读取，不存在 → error。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.Prep
  alias Cgc2046.Mcp.Wrapper
  alias Cgc2046.PendingApprovals
  alias Cgc2046.Workflows.WorkflowRun

  require Ash.Query

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "list_my_tasks", fn actor, workspace_id, _params ->
        with {:ok, workspace} <- fetch_workspace(workspace_id, actor),
             {:ok, rows} <- PendingApprovals.list(actor) do
          approval_tasks = Enum.filter(rows, &(&1.workspace_id == workspace.id))
          prep_tasks = prep_tasks(actor, workspace)

          tasks = approval_tasks ++ prep_tasks

          {:ok, %{tasks: tasks, count: length(tasks), workspace_id: workspace.id}}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 成员身份已由 Wrapper member-only 门保证，此处以 actor 授权读工作台（invite_only
  # 工作台非成员不可读，与门语义一致）。
  defp fetch_workspace(workspace_id, actor) do
    case Workspace
         |> Ash.Query.for_read(:get_by_id, %{id: workspace_id})
         |> Ash.read_one(actor: actor) do
      {:ok, nil} -> {:error, "workspace not found: #{workspace_id}"}
      {:ok, workspace} -> {:ok, workspace}
      {:error, _} -> {:error, "failed to load workspace"}
    end
  end

  # ── 课程教研任务行（S5）───────────────────────────────────────────

  # 本工作台非终态 prep run → 按 actor 角色分派三类任务；课程标题批量装配
  # （内部读 authorize?: false——行可见性已由 member 门 + 下方角色分派保证，
  # 标题只是同权限范围内的展示字段，PendingApprovals enrich 同款纪律）
  defp prep_tasks(actor, workspace) do
    runs =
      WorkflowRun
      |> Ash.Query.filter(
        definition.type == :course_preparation and
          status in [:pending, :running, :waiting]
      )
      |> Ash.read!(authorize?: false, tenant: workspace.id)

    manage = Prep.manage?(actor, workspace.id)
    tutor = Prep.tutor?(actor, workspace.id)

    rows =
      Enum.flat_map(runs, fn run ->
        case classify(run, actor, manage, tutor) do
          nil -> []
          kind -> [prep_row(run, kind, workspace)]
        end
      end)

    attach_course_titles(rows, workspace.id)
  end

  defp classify(run, actor, manage, tutor) do
    state = Prep.prep_state(run)
    assignee = Prep.assignee(run)

    cond do
      state == "draft" and is_nil(assignee) and (tutor or manage) ->
        "course_prep_claimable"

      assignee == actor.id and state in ["authoring", "quality_check"] ->
        "course_prep_authoring"

      state == "review" and (manage or Prep.reviewer?(run, actor)) ->
        "course_prep_review"

      true ->
        nil
    end
  end

  defp prep_row(run, kind, workspace) do
    %{
      id: run.id,
      kind: kind,
      workspace_id: workspace.id,
      workspace_slug: workspace.slug,
      course_id: (run.input_snapshot || %{})["course_id"],
      prep_state: Prep.prep_state(run),
      context_title: nil
    }
  end

  defp attach_course_titles(rows, workspace_id) do
    ids = rows |> Enum.map(& &1.course_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    titles =
      Course
      |> Ash.Query.filter(id in ^ids)
      |> Ash.read!(authorize?: false, tenant: workspace_id)
      |> Map.new(fn course -> {course.id, course.title} end)

    Enum.map(rows, fn row -> %{row | context_title: Map.get(titles, row.course_id)} end)
  end
end
