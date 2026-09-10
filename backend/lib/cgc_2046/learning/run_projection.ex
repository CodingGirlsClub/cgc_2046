defmodule Cgc2046.Learning.RunProjection do
  @moduledoc """
  学习 run 投影组装（ADR-0010 批次 3：自 Cgc2046Web.GraphqlSchema 抽离；
  S8 切 objective 口径——ADR-0011；issue #505 D8 切 user 维度）。

  把 (WorkflowRun, actor) 二元组投影为 myLearningRuns 行：subject 列本人锚
  （subject_user_id == actor.id，查询侧已过滤此处双保险）→
  `Runs.learning_state/2` 单源投影（MCP 与 GraphQL 共用，ADR-0011 L6）→
  展示行组装。D8 汇流后 run 锚的 enrollment 可以是活动或课程报名行，
  展示元数据（title/course_id/enrollment_id）全部取自 run 自身
  （input_snapshot 固化 title + subject 列），enrollment 链守门退役。
  """

  alias Cgc2046.Learning.Runs

  @doc """
  投影单个 learning run；本人锚校验失败、或课程已取消（cancelled
  offering 不进学习列表）返回 nil（调用方 reject）。
  `titles` = 查询侧批量反查的 `%{enrollment_id => target_title}`（展示用
  快照标题，不参与守门）。
  """
  def project_run(run, actor, titles \\ %{}) do
    definition = Map.get(run, :definition)
    course = fetch_course(run.workspace_id, run.subject_course_id)

    cond do
      run.subject_user_id != actor.id ->
        nil

      not learning_definition?(definition) ->
        nil

      # 课程取消后不再出现在学习列表（存量 run 由 Learning.RunReaper 级联
      # 停掉；本守卫覆盖取消前已终态/未回收的行）
      match?(%{status: :cancelled}, course) ->
        nil

      true ->
        # 本人锚已立（subject_user_id 校验），learning_state 读取 run 的
        # attempts 无他人视角可构造。
        state = Runs.learning_state(actor, course)

        %{
          run_id: run.id,
          enrollment_id: run.subject_enrollment_id,
          target_title: Map.get(titles, run.subject_enrollment_id) || run_title(run),
          status: to_string(run.status),
          course_id: run.subject_course_id,
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

  # 标题真源 = 创建时固化的 input_snapshot["title"]（活动/课程报名行均可
  # 变更/删除，快照不随动）。
  defp run_title(%{input_snapshot: %{"title" => title}}) when is_binary(title),
    do: title

  defp run_title(_run), do: nil

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

  defp learning_definition?(%{type: :learning}), do: true
  defp learning_definition?(_definition), do: false
end
