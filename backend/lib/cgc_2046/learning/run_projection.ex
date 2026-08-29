defmodule Cgc2046.Learning.RunProjection do
  @moduledoc """
  学习 run 投影组装（ADR-0010 批次 3：自 Cgc2046Web.GraphqlSchema 抽离）。

  把 (WorkflowRun, Enrollment, actor) 三元组投影为 myLearningRuns 的
  LearningProgress 行：本人锚链校验（#217 D 类旁路读取守门）→ 内容/记录/课程
  同源组装 → Cgc2046.Learning.Progress.project 权威投影 → current_issue_key
  展示层派生（KTD6）。

  resolver（GraphqlSchema.resolve_my_learning_runs）只负责 enrollment/run 枚举，
  投影规则全部收敛于此。
  """

  require Ash.Query

  @doc """
  投影单个 learning run；本人锚链任一校验失败返回 nil（调用方 reject）。
  """
  def project_run(run, enrollment, actor) do
    definition = Map.get(run, :definition)

    cond do
      enrollment.user_id != actor.id ->
        nil

      not anchored_to_enrollment?(run, enrollment) ->
        nil

      run.workspace_id != enrollment.workspace_id ->
        nil

      not learning_definition?(definition) ->
        nil

      true ->
        target_title =
          if is_binary(enrollment.target_title), do: enrollment.target_title, else: nil

        # U7(#180):issue 级权威投影(course content + learning_records);
        # manual_steps_compat/旧字段派生已删(KD8),issue key 展示层派生(KTD6)
        {content, records, course} = learning_projection_sources(run, enrollment)

        Cgc2046.Learning.Progress.project(
          run.id,
          enrollment.id,
          target_title,
          run.status,
          content,
          records
        )
        |> Map.put(:course_id, enrollment.course_id)
        |> Map.put(:current_issue_key, current_issue_key(course, content, records))
    end
  end

  # U7:内容/记录/课程按 (course, user) 组装(无内容课程 → nil → 投影 0/n)。
  # course 供 issue key 派生(slug 短码);一次往返,抽屉数据同源。
  # #217 旁路读取（D 类·本人锚链）：本函数三处直读（Curriculum.Output 内容 /
  # LearningRecord 记录 / Course 元数据）由同一调用链守门——
  # project_run 已校验 enrollment.user_id == actor.id，records 再按
  # user_id 过滤本人；无他人视角可构造。
  defp learning_projection_sources(run, enrollment) do
    course_id = enrollment.course_id

    if is_binary(course_id) do
      content =
        case Cgc2046.Curriculum.content_output(run.workspace_id, course_id) do
          {:ok, output} -> output && output.data
          _ -> nil
        end

      # #217 旁路读取（D 类·本人锚）：user_id 过滤，锚链同函数头注释。
      records =
        if is_binary(enrollment.user_id) do
          Cgc2046.Learning.LearningRecord
          |> Ash.Query.filter(course_id == ^course_id and user_id == ^enrollment.user_id)
          |> Ash.read!(authorize?: false, tenant: run.workspace_id)
        else
          []
        end

      # #217 旁路读取（D 类）：投影元数据，守门同函数头锚链。
      course =
        Cgc2046.Courses.Course
        |> Ash.Query.for_read(:get_by_id, %{id: course_id})
        |> Ash.read_one(authorize?: false, tenant: run.workspace_id)
        |> case do
          {:ok, nil} -> nil
          {:ok, course} -> course
          _ -> nil
        end

      {content, records, course}
    else
      {nil, [], nil}
    end
  end

  # issue key 展示层派生(KTD6):当前 issue 在卡集中的 1 起序号 + 课程 slug 短码。
  # current_issue_id 由 records 视角派生(全 Done → nil → key nil)
  defp current_issue_key(course, content, records) do
    issues = Cgc2046.Curriculum.Content.issues(content)

    with %{current_issue_id: issue_id} when is_binary(issue_id) <-
           Cgc2046.Learning.Progress.project_issues(content, records),
         idx when is_integer(idx) <- Enum.find_index(issues, &(&1["id"] == issue_id)) do
      Cgc2046.Learning.Progress.issue_key(course && course.slug, idx + 1)
    else
      _ -> nil
    end
  end

  defp anchored_to_enrollment?(%{input_snapshot: input}, %{id: enrollment_id})
       when is_map(input) do
    Map.get(input, "enrollment_id") == enrollment_id or
      Map.get(input, :enrollment_id) == enrollment_id
  end

  defp anchored_to_enrollment?(_run, _enrollment), do: false

  defp learning_definition?(%{type: type}) when type in [:learning, "learning"], do: true
  defp learning_definition?(_definition), do: false
end
