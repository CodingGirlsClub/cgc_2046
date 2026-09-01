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

  授权 = Wrapper 默认 fail-closed member 门（`list_my_tasks` 同款）：
  workspace member 可读全部状态（含 draft）——域 read policy 对 member
  收窄 draft（`Offering.ActorReadsOffering`），本面读门禁在 Wrapper 层
  已真实发生，课程直读走 `authorize?: false`（`get_course_content`
  fetch_course 同款纪律）。
  """

  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.Prep
  alias Cgc2046.Mcp.Wrapper

  require Ash.Query

  @limit 100

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID(UUID)")

    field(:status, :string, description: "按状态过滤（可选：draft | open | closed | cancelled）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "list_workspace_courses", fn _actor, workspace_id, params ->
        with {:ok, status} <- parse_status(params["status"] || params[:status]),
             {:ok, rows} <- read_courses(workspace_id, status) do
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

  # member 门已在 Wrapper 层真实发生（非成员 forbidden 落审计）；tenant 锁
  # 工作台归属，authorize?: false 直读全部状态（含 draft）。workflow_run
  # 关系行一并 load——prep_state 投影消费（facts 未写 = "draft"，nil run = nil）。
  defp read_courses(workspace_id, status) do
    Course
    |> scope_status(status)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.limit(@limit)
    |> Ash.Query.load(:workflow_run)
    |> Ash.read(authorize?: false, tenant: workspace_id)
    |> case do
      {:ok, courses} -> {:ok, Enum.map(courses, &to_row/1)}
      {:error, _} = err -> err
    end
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
      prep_state: course.workflow_run && Prep.prep_state(course.workflow_run)
    }
  end
end
