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
  - 本人 confirmed enrollment（学员）→ 仅最新 published 版本；
  - 其他 → forbidden。

  从未发布过的课程返回「无已发布版本」明确错误（不回退草稿——草稿读面是
  get_course_content；公开 courseMap 的草稿回退与本工具无关）。
  """
  use Anubis.Server.Component, type: :tool, meta: %{membership: :deferred}

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum
  alias Cgc2046.Mcp.Tools.LearnerAuthorization
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID(UUID)")
    field(:course_id, {:required, :string}, description: "课程 ID(UUID)")

    field(:revision_number, :integer, description: "版本号（≥1 整数；缺省 = 最新已发布版本）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "get_course_revision", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]
        revision_number = params["revision_number"] || params[:revision_number]

        with {:ok, course} <- fetch_course(workspace_id, course_id),
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
             issues: content["issues"] || []
           }}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 课程存在性（租户收紧）；授权在工具层发生，authorize?: false 直读
  # （get_course_content fetch_course 同款纪律）。
  defp fetch_course(workspace_id, course_id) do
    case Course
         |> Ash.Query.for_read(:get_by_id, %{id: course_id})
         |> Ash.read_one(authorize?: false, tenant: workspace_id) do
      {:ok, nil} -> {:error, "course not found: #{course_id}"}
      {:ok, course} -> {:ok, course}
      {:error, _} -> {:error, "failed to load course"}
    end
  end

  # 授权三段：成员任意版本；confirmed 学员仅最新（缺省或显式等于最新号）；
  # 其余拒绝。latest 为 nil（从未发布）时学员只放行缺省读（随后报无版本）。
  defp authorize(actor, workspace_id, course_id, latest, revision_number) do
    cond do
      member?(actor, workspace_id) ->
        :ok

      LearnerAuthorization.confirmed_enrollment?(actor, workspace_id, course_id) ->
        if revision_number == nil || (latest != nil && revision_number == latest.number) do
          :ok
        else
          {:error, "forbidden: enrolled learners can only read the latest published revision"}
        end

      true ->
        {:error, "forbidden: workspace member or enrolled learner required"}
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
