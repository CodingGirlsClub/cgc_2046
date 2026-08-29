defmodule Cgc2046.Mcp.Tools.GetLearningState do
  @moduledoc """
  学员学习状态投影(role-agent-journeys-v2 S8,R39/R40/R43)。

  数据源 = `Cgc2046.Learning.Runs.learning_state/2`(GraphQL
  courseLearningDetail 共用同一投影单源):

  - `run`:最新 learning run 摘要(任意状态,完成态仍可展示;无 run → null);
  - `revision_number`:课程当前 published 版本号(从未发布 → null);
  - `stale_revision`:run 绑定旧版本时为 true——投影报 **run 自己版本**的
    objectives 与掌握态(学完旧版前不被新版内容 silently 换底),发布新版后
    调 `start_learning_run` 开新版 run;
  - `objectives`:objective 粒度掌握投影(id/title/required/issue_id/
    prereq_ids/mastery/ever_mastered/locked/missing_prereq_ids/attempt_count/
    last_attempt_at);
  - `review_queue`:S8 恒缺席(ReviewSchedule 属 S9,R45——届时由
    `Learning.ReviewSchedule.due/3` 派生真实队列);
  - `next_action`:R40 推荐(%{kind, objective_id, reason},reason 含目标
    标题——playbook 要求 agent 按 reason 向学员解释起点;复习到期优先
    (needs_review 条目 reason 明示「待复习」);课程完成 → null);
  - `progress`:%{mastered_required, total_required, complete}(R39 完成 =
    必修全 ever_mastered,needs_review 不倒退)。

  授权(`membership: :deferred`,工具层判定):workspace 成员 ∪ 本人
  confirmed enrollment ∪ 本人学习 run 持有者(「曾学过」读面,含课程
  close/cancel 后)——`LearnerAuthorization.authorize/3`。
  """
  use Anubis.Server.Component, type: :tool, meta: %{membership: :deferred}

  alias Cgc2046.Learning.Runs
  alias Cgc2046.Mcp.Tools.{LearnerAuthorization, Response}
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID(UUID)")
    field(:course_id, {:required, :string}, description: "课程 ID(UUID)")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "get_learning_state", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]

        with :ok <- LearnerAuthorization.authorize(actor, workspace_id, course_id),
             {:ok, course} <- fetch_course(workspace_id, course_id) do
          {:ok, serialize(Runs.learning_state(actor, course))}
        end
      end)

    Response.to_response(result, frame)
  end

  # 课程存在性(租户收紧);授权已在工具层发生,authorize?: false 直读
  # (get_course_revision fetch_course 同款纪律)
  defp fetch_course(workspace_id, course_id) do
    case Cgc2046.Courses.Course
         |> Ash.Query.for_read(:get_by_id, %{id: course_id})
         |> Ash.read_one(authorize?: false, tenant: workspace_id) do
      {:ok, nil} -> {:error, "course not found: #{course_id}"}
      {:ok, course} -> {:ok, course}
      {:error, _} -> {:error, "failed to load course"}
    end
  end

  # DateTime → ISO8601;atom kind/state 已在投影层 to_string(mastery),
  # 此处处理 last_attempt_at / review_queue.due_at 与 next_action.kind
  defp serialize(state) do
    %{
      run: state.run,
      revision_number: state.revision_number,
      stale_revision: state.stale_revision,
      objectives:
        Enum.map(state.objectives, fn objective ->
          %{objective | last_attempt_at: iso8601(objective.last_attempt_at)}
        end),
      next_action: serialize_next_action(state.next_action),
      progress: state.progress
    }
  end

  defp serialize_next_action(nil), do: nil

  defp serialize_next_action(%{kind: kind} = action) do
    %{action | kind: to_string(kind)}
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
