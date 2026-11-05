defmodule Cgc2046.Mcp.Tools.ListWorkspaceCourses do
  @moduledoc """
  列出工作台全部课程（#366）——教研/管理工作台面板的可编辑课程发现面。

  `get_my_enrollments` 只回本人报名的课程；tutor 有权编辑课程内容
  （`get_course_content` / `save_course_content`）却不必然报名——教研工作台
  需要「本台全部课程」的发现面（含 draft——教研最需要看到的阶段）。
  `discover_offerings` 仅 open+public，不含 draft，不满足。

  返回：`course_id / title / status / visibility / current_revision_id /
  prep_state`（`workflow_run_id` 为 nil 的断流课程 prep_state = nil）。
  `status` 可选过滤（draft|open|closed|cancelled）。按创建时间正序，
  封顶 100。

  授权 = Wrapper 成员门 + 领域 actor 读：普通成员 open/closed，tutor 另可读 draft，
  Owner/Admin 全部状态。MCP 与领域读取共用状态授权单源（#1084）。
  """

  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Courses.Course
  alias Cgc2046.Mcp.Wrapper
  alias Cgc2046.Workflows.WorkflowRun

  require Ash.Query

  @limit 100

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    List courses visible to the caller in a workspace. Members can read open/closed courses; tutors
    can also read draft courses; owners/admins can read all statuses. Optional status filter:
    draft | open | closed | cancelled. Returns course_id, title, status, visibility,
    current_revision_id and prep_state (null without a preparation workflow), ordered by creation,
    up to 100 rows. Learners looking for available enrollment can use discover_offerings.
    """
  end

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID(UUID)")

    field(:status, :string, description: "按状态过滤（可选：draft | open | closed | cancelled）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "list_workspace_courses", fn actor, workspace_id, params ->
        with {:ok, status} <- parse_status(params["status"]),
             {:ok, rows} <- read_courses(actor, workspace_id, status) do
          {:ok, %{count: length(rows), courses: rows}}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 空串/nil = 不过滤；值经 Course.status_values/1 白名单（非法值报错带清单）
  defp parse_status(nil), do: {:ok, nil}
  defp parse_status(""), do: {:ok, nil}

  defp parse_status(status) when is_binary(status) do
    values = Course.status_values()

    case Enum.find(values, &(to_string(&1) == status)) do
      nil ->
        {:error, "invalid status (expected one of #{Enum.map_join(values, "|", &to_string/1)})"}

      atom ->
        {:ok, atom}
    end
  end

  defp parse_status(_), do: {:error, "status must be a string"}

  # actor 读由领域 policy 约束状态；关系投影只加载 id 与 prep_state，避免读整份 facts。
  defp read_courses(actor, workspace_id, status) do
    Course
    |> scope_status(status)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.limit(@limit)
    |> Ash.Query.load(workflow_run: workflow_run_projection())
    |> Ash.read(actor: actor, tenant: workspace_id)
    |> case do
      {:ok, courses} -> {:ok, Enum.map(courses, &to_row/1)}
      {:error, _} = err -> err
    end
  end

  # prep_state = SQL 下推 COALESCE(facts["prep_state"], 'draft')（与
  # Prep.prep_state/1 同源，#1126）；nil run（无教研流程）为 nil
  defp workflow_run_projection do
    WorkflowRun
    |> Ash.Query.select([:id])
    |> Ash.Query.load(:prep_state)
  end

  # filter 宏不接受任意控制流（if AST 不被识别）——分支在宏外
  defp scope_status(query, nil), do: query
  defp scope_status(query, status), do: Ash.Query.filter(query, status == ^status)

  defp to_row(course) do
    %{
      course_id: course.id,
      title: course.title,
      status: course.status,
      visibility: course.visibility,
      current_revision_id: course.current_revision_id,
      # prep_state = SQL 下推 COALESCE(facts["prep_state"], 'draft')（缺省
      # draft，与 get_prep_status 同源）；nil run（无教研流程）为 nil
      prep_state: course.workflow_run && course.workflow_run.prep_state
    }
  end
end
