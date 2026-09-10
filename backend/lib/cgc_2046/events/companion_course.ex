defmodule Cgc2046.Events.CompanionCourse do
  @moduledoc """
  `companionCourse` 公开读面投影（issue #505 D1/1h）：event 配套课锚点
  （course_revision_id）→ 课程卡展示字段（id/slug/title）的批量投影。

  event.course_revision_id 属性本身不进公开 SDL（courses.current_revision_id
  同款纪律），公开页经本计算字段拿渲染所需最小集。无锚（宣讲会）→ nil。
  """

  require Ash.Query

  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.CourseRevision

  @doc """
  calculation 入口：events（可跨租户）→ 逐个投影 map 或 nil。
  revision/course 均 global?(true)，两趟批量 IN 查询，无 N+1。
  """
  @spec project([%{course_revision_id: String.t() | nil}]) :: [map() | nil]
  def project(records) do
    revision_ids =
      records |> Enum.map(& &1.course_revision_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    course_by_revision = courses_by_revision(revision_ids)

    Enum.map(records, fn record ->
      case record.course_revision_id do
        nil -> nil
        revision_id -> Map.get(course_by_revision, revision_id)
      end
    end)
  end

  defp courses_by_revision([]), do: %{}

  defp courses_by_revision(revision_ids) do
    revisions =
      CourseRevision
      |> Ash.Query.filter(id in ^revision_ids)
      |> Ash.Query.select([:id, :course_id])
      |> Ash.read!(authorize?: false)

    course_ids = revisions |> Enum.map(& &1.course_id) |> Enum.uniq()

    courses =
      Course
      |> Ash.Query.filter(id in ^course_ids)
      |> Ash.Query.select([:id, :slug, :title])
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.id, &1})

    Map.new(revisions, fn revision ->
      case Map.get(courses, revision.course_id) do
        nil ->
          {revision.id, nil}

        course ->
          {revision.id, %{id: course.id, slug: course.slug, title: course.title}}
      end
    end)
  end
end
