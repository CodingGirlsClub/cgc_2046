defmodule Cgc2046.Learning.RunProjection do
  @moduledoc """
  学习 run 投影组装（ADR-0010 批次 3：自 Cgc2046Web.GraphqlSchema 抽离；
  S8 切 objective 口径——ADR-0011）。

  把 (WorkflowRun, Enrollment, actor) 三元组投影为 myLearningRuns 行：本人
  锚链校验（#217 D 类旁路读取守门，随迁纪律保留）→ `Runs.learning_state/2`
  单源投影（MCP 与 GraphQL 共用，ADR-0011 L6）→ 展示行组装。

  resolver（GraphqlSchema.resolve_my_learning_runs）只负责 enrollment/run
  枚举，投影规则全部收敛于此。
  """

  alias Cgc2046.Learning.Runs

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

        # #217 旁路读取（D 类·本人锚链）：learning_state 读取 run 的 attempts
        # （run 锚定 user_id == enrollment.user_id == actor.id 已三重校验），
        # 无他人视角可构造。
        course = fetch_course(run.workspace_id, enrollment.course_id)
        state = Runs.learning_state(actor, course)

        %{
          run_id: run.id,
          enrollment_id: enrollment.id,
          target_title: target_title,
          status: to_string(run.status),
          course_id: enrollment.course_id,
          stale_revision: state.stale_revision,
          progress: %{
            mastered_required: state.progress.mastered_required,
            total_required: state.progress.total_required,
            complete: state.progress.complete
          },
          next_action: state.next_action && next_action_row(state.next_action)
        }
    end
  end

  defp next_action_row(%{kind: kind, objective_id: objective_id, reason: reason}) do
    %{kind: to_string(kind), objective_id: objective_id, reason: reason}
  end

  # 课程元数据（title 已由 target_title 承担；课程缺失时 learning_state 退化为
  # 空投影——run 枚举仍展示行）。#217 旁路读取守门同 project_run 头注。
  defp fetch_course(workspace_id, course_id) when is_binary(course_id) do
    Cgc2046.Courses.Course
    |> Ash.Query.for_read(:get_by_id, %{id: course_id})
    |> Ash.read_one(authorize?: false, tenant: workspace_id)
    |> case do
      {:ok, nil} -> nil
      {:ok, course} -> course
      _ -> nil
    end
  end

  defp fetch_course(_workspace_id, _course_id), do: nil

  defp anchored_to_enrollment?(%{input_snapshot: input}, %{id: enrollment_id})
       when is_map(input) do
    Map.get(input, "enrollment_id") == enrollment_id or
      Map.get(input, :enrollment_id) == enrollment_id
  end

  defp anchored_to_enrollment?(_run, _enrollment), do: false

  defp learning_definition?(%{type: :learning}), do: true
  defp learning_definition?(_definition), do: false
end
