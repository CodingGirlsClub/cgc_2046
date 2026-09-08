defmodule Cgc2046.Courses.CourseProjection do
  @moduledoc """
  课程读者投影（2026-09-08 架构评审候选③；仿 `Learning.RunProjection` 先例
  自 `Cgc2046Web.GraphqlSchema` 抽离）：course 形读者面的 fetch + 授权姿态 +
  投影组装的单源。四种公开函数 = 四种授权姿态：

  - `map_by_slug/1`——**公开**：仅 `status == :open ∧ visibility == :public`，
    匿名可读；goal-only 投影（`course_map` 无 checklist 字段），其余统一 nil。
  - `learning_detail/2`、`content/2`——**学员三层**（`Learning.Authorization`：
    成员 ∪ 本人 confirmed enrollment ∪ 本人学习 run 持有者）；无权/无课程
    统一 `{:ok, nil}`（404 语义，不泄露存在性）。
  - `draft/2`——**staff**（`Rbac.staff?/2`：tutor ∪ owner/admin），不向
    learner 暴露；无权/课程不存在统一 nil。

  fetch 是 #217 旁路读取（D 类·显式判定前置）：`authorize?: false` 直读，
  门禁由上述各姿态判定承担。无权限一律 nil 而非 forbidden——存在性不可枚举。
  """

  alias Cgc2046.Accounts.Rbac
  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum
  alias Cgc2046.Learning.{Authorization, Runs}

  @doc "公开课程地图（U7/R10）：issue key/标题/kind/goal 一行；非 open+public 统一 nil。"
  @spec map_by_slug(String.t()) :: {:ok, map() | nil}
  def map_by_slug(slug) do
    case Course
         |> Ash.Query.for_read(:get_by_slug, %{slug: slug})
         |> Ash.read_one(authorize?: false) do
      {:ok, %{} = course} ->
        if course.status == :open and course.visibility == :public do
          {:ok, build_map(course)}
        else
          {:ok, nil}
        end

      _ ->
        {:ok, nil}
    end
  end

  @doc """
  学员视角课程学习详情（U7 抽屉数据；恒 actor——授权 = 学员侧三层，
  无他人视角可构造）。投影 = `Runs.learning_state/2` 组装（objective 口径）。
  """
  @spec learning_detail(term(), String.t()) :: {:ok, map() | nil}
  def learning_detail(actor, course_id) do
    with %{} = course <- fetch(course_id),
         :ok <- Authorization.authorize(actor, course.workspace_id, course.id) do
      state = Runs.learning_state(actor, course)

      {:ok,
       %{
         course_id: course.id,
         title: course.title,
         slug: course.slug,
         run: state.run,
         revision_number: state.revision_number,
         stale_revision: state.stale_revision,
         review_queue: state.review_queue,
         objectives: state.objectives,
         next_action: state.next_action,
         progress: state.progress
       }}
    else
      _ -> {:ok, nil}
    end
  end

  @doc "学员可读的最新已发布课程内容（chapter + typed materials；不含原始 WorkflowRun）。"
  @spec content(term(), String.t()) :: {:ok, map() | nil}
  def content(actor, course_id) do
    with %{} = course <- fetch(course_id),
         :ok <- Authorization.authorize(actor, course.workspace_id, course.id),
         {:ok, revision} <- Curriculum.latest_revision(course.workspace_id, course.id),
         %{} = revision <- revision do
      {:ok,
       %{
         course_id: course.id,
         title: course.title,
         revision_number: revision.number,
         published_at: revision.published_at,
         content: revision.content || %{}
       }}
    else
      _ -> {:ok, nil}
    end
  end

  @doc """
  课程草稿读面（H6，staff-only）：数据源 = Curriculum Output 活文档草稿
  （`content_output/2` 单一读入口，无草稿 → version/content 为 nil）+
  prep run 纯读（不沿用 `get_prep_status` 的 ensure_active_run 懒开——
  GraphQL query 不得带写效应；无活动 prep run → null）。
  """
  @spec draft(term(), String.t()) :: {:ok, map() | nil}
  def draft(actor, course_id) do
    with %{} = course <- fetch(course_id),
         true <- Rbac.staff?(actor, course.workspace_id),
         {:ok, output} <- Curriculum.content_output(course.workspace_id, course.id) do
      prep_run = Curriculum.Prep.fetch_run(course.id, course.workspace_id)

      {:ok,
       %{
         course_id: course.id,
         title: course.title,
         version: output && output.version,
         prep_state: prep_run && Curriculum.Prep.prep_state(prep_run),
         updated_at: output && output.updated_at,
         content: output && (output.data || %{})
       }}
    else
      _ -> {:ok, nil}
    end
  end

  # S6（R29）：内容源 = 当前 published CourseRevision（发布即冻结，草稿后续
  # 编辑不影响公开面）；无 revision 的存量课程回退草稿读面（旧行为）。
  # 投影形状（goal-only）不变——公开 SDL 零 diff。
  defp build_map(course) do
    content = Course.published_content(course) || %{}

    %{
      course_id: course.id,
      title: course.title,
      slug: course.slug,
      goals: content["goals"] || [],
      issues: Curriculum.issue_map_rows(course, content)
    }
  end

  # #217 旁路读取（D 类·显式判定前置）：Course 直读定位，门禁由调用方的
  # 授权姿态判定（学员三层 / staff）承担，无权限 → nil。
  defp fetch(course_id) do
    Course
    |> Ash.Query.for_read(:get_by_id, %{id: course_id})
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{} = course} -> course
      _ -> nil
    end
  end
end
