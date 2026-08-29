defmodule Cgc2046.Mcp.Tools.SubmitLearningAttempt do
  @moduledoc """
  提交一次正式学习评价(role-agent-journeys-v2 S8,R41-R44)。

  落一行**不可变** `LearningAttempt`(无 update/destroy;失败评价永不删除,
  重试写新行,R44),随后:

  -  mastery 由 `Cgc2046.Learning.Mastery` 从 attempts 纯投影派生(agent
     永不直写);qualifying 判据 = passed ∧ confidence ≥ 0.8 ∧ rubric 精确
     覆盖且逐条 met(判据单源 `Mastery.qualifying?/2`);
  -  **即时完成判定**:attempt 落库后立即调 `Runs.complete_when_mastered/1`
     ——必修 objective 全 ever_mastered 即置 run succeeded(不等 5 分钟
     worker)。刻意**非同事务**:completion 失败不回滚 attempt(账本为真源,
     worker 兜底收敛),且 complete 的 checkpoint 清理 after_transaction
     hook 不应跑在外层事务内;
  -  返回该 objective 新掌握态 + run 是否完成 + 下一动作推荐(R40;S9 起
     复习到期队列同源——掌握后复习失败翻转 needs_review 时,next_action
     优先回补该 objective)。

  **掌握后评价即复习**(S9,R45):submit 参数不变、无复习标记——对已掌握
  objective 的正式评价自动构成间隔重复复习(1/7/30 天里程碑按序消费,
  见 `Cgc2046.Learning.ReviewSchedule`);失败翻转 needs_review 但**不撤销**
  已完成的 run(AE10——终态 run 本无 active run,提交会被拒,完成结果
  不可撤销)。

  校验链(工具层,全 fail-fast 明确错误):

  1. 授权(`membership: :deferred`):仅本人 confirmed enrollment 的学员
     可提交(tutor/owner/admin 只读不代写;资源层 `ActorIsAttemptLearner`
     SimpleCheck 兜底);
  2. 须有非终态 learning run(无 → 提示先 `start_learning_run`);
  3. run 须绑定课程 revision(存量 nil 宽限 run 不可评价);
  4. objective 须存在于该 revision;rubric_results 须**精确覆盖**其 rubric
     全部 criterion id(不多不少,`Mastery.rubric_exact?/2`);
  5. confidence ∈ 0..1;evidence / rationale 非空;
  6. **先修锁(R41)**:objective 未解锁(有先修未 ever_mastered)→ 拒绝,
     报缺失先修 id+title——锁定不可绕过,先补先修。
  """
  use Anubis.Server.Component, type: :tool, meta: %{membership: :deferred}

  require Logger

  alias Cgc2046.Learning.{Attempt, Mastery, NextAction, Runs}
  alias Cgc2046.Mcp.Tools.Response
  alias Cgc2046.Mcp.Wrapper
  alias Cgc2046.Curriculum.Content

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID(UUID)")
    field(:course_id, {:required, :string}, description: "课程 ID(UUID)")
    field(:objective_id, {:required, :string}, description: "掌握单元 id(版本快照内稳定 id)")
    field(:evidence, {:required, :string}, description: "学员提交的证据/作答摘要(非空)")

    field(:rubric_results, {:required, {:list, :map}},
      description: "逐条评分结果 [%{criterion_id, met, note?}];须精确覆盖 objective rubric 全部 criterion id"
    )

    field(:passed, {:required, :boolean}, description: "agent 判定的通过与否(不构成掌握——掌握由投影派生)")
    field(:rationale, {:required, :string}, description: "判定理由摘要(非空)")

    field(:confidence, {:required, :float},
      description: "判定置信度 0..1;< 0.8 不构成 qualifying 掌握(rubric 未全达标同理)"
    )

    field(:agent_meta, :map, description: "agent 元数据(客户端名/模型等;可选)")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "submit_learning_attempt", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]
        objective_id = params["objective_id"] || params[:objective_id]

        with :ok <- ensure_enrolled(actor, workspace_id, course_id),
             {:ok, run} <- active_run(actor, workspace_id, course_id),
             {:ok, revision} <- bound_revision(run),
             {:ok, objective, objectives} <- fetch_objective(revision, objective_id),
             {:ok, rubric_results} <- validate_rubric(params, objective),
             {:ok, confidence} <- validate_confidence(params),
             {:ok, evidence} <- non_empty(params, "evidence"),
             {:ok, rationale} <- non_empty(params, "rationale"),
             attempts <- Runs.attempts_for(run),
             states <- Mastery.states(attempts, objectives),
             :ok <- ensure_unlocked(objective, objectives, states) do
          record_attempt(
            actor,
            workspace_id,
            run,
            revision,
            objective,
            objectives,
            attempts,
            %{
              objective_id: objective_id,
              evidence: evidence,
              rubric_results: rubric_results,
              passed: params["passed"] == true || params[:passed] == true,
              rationale: rationale,
              confidence: confidence,
              agent_meta: params["agent_meta"] || params[:agent_meta] || %{}
            }
          )
        end
      end)

    Response.to_response(result, frame)
  end

  # --- 校验链 -----------------------------------------------------------------

  defp ensure_enrolled(actor, workspace_id, course_id) do
    if Runs.confirmed_enrollment?(actor, workspace_id, course_id) do
      :ok
    else
      {:error, "forbidden: confirmed enrollment required to submit learning attempt"}
    end
  end

  defp active_run(actor, workspace_id, course_id) do
    case Runs.active_run_for(actor, workspace_id, course_id) do
      nil ->
        {:error, "no active learning run for course #{course_id}; call start_learning_run first"}

      run ->
        {:ok, run}
    end
  end

  defp bound_revision(run) do
    case Runs.revision_of(run) do
      {:ok, nil} ->
        {:error,
         "learning run #{run.id} has no bound course revision; attempts require a published revision"}

      {:ok, revision} ->
        {:ok, revision}
    end
  end

  defp fetch_objective(revision, objective_id) do
    objectives = Content.objectives(revision.content || %{})

    case Enum.find(objectives, &(&1["id"] == objective_id)) do
      nil ->
        {:error,
         "objective #{inspect(objective_id)} not found in course revision #{revision.number} " <>
           "(known ids: #{objectives |> Enum.map(& &1["id"]) |> Enum.join(", ")})"}

      objective ->
        {:ok, objective, objectives}
    end
  end

  # rubric_results 规整为 string 键 map(MCP 入参经 Jason 解码已是 string 键,
  # 直调/测试路径可能给 atom 键)+ 精确覆盖校验(判据单源 Mastery.rubric_exact?/2)
  defp validate_rubric(params, objective) do
    case params["rubric_results"] || params[:rubric_results] do
      results when is_list(results) ->
        normalized = Enum.map(results, &normalize_result/1)

        if Mastery.rubric_exact?(normalized, objective) do
          {:ok, normalized}
        else
          expected = objective |> rubric_ids() |> Enum.sort()
          got = normalized |> Enum.map(& &1["criterion_id"]) |> Enum.sort()

          {:error,
           "rubric_results must cover exactly the objective's rubric criteria " <>
             "(expected: #{inspect(expected)}; got: #{inspect(got)})"}
        end

      _ ->
        {:error, "rubric_results must be a list of %{criterion_id, met, note?}"}
    end
  end

  defp normalize_result(result) when is_map(result) do
    Map.new(result, fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_result(other), do: %{"_invalid" => inspect(other)}

  defp rubric_ids(objective) do
    case objective["rubric"] do
      rubric when is_list(rubric) -> Enum.map(rubric, & &1["id"])
      _ -> []
    end
  end

  defp validate_confidence(params) do
    case params["confidence"] || params[:confidence] do
      value when is_float(value) and value >= 0.0 and value <= 1.0 ->
        {:ok, value}

      value when is_integer(value) and value >= 0 and value <= 1 ->
        {:ok, value * 1.0}

      _ ->
        {:error, "confidence must be a number in 0..1"}
    end
  end

  defp non_empty(params, key) do
    case params[key] || params[String.to_atom(key)] do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, "#{key} must be non-empty"}, else: {:ok, value}

      _ ->
        {:error, "#{key} must be a non-empty string"}
    end
  end

  # R41 先修锁:缺失先修报 id+title,不可绕过
  defp ensure_unlocked(objective, objectives, states) do
    if NextAction.unlocked?(objective, states) do
      :ok
    else
      missing =
        objective
        |> NextAction.missing_prereq_ids(states)
        |> Enum.map(fn prereq_id ->
          title =
            case Enum.find(objectives, &(&1["id"] == prereq_id)) do
              %{"title" => title} -> title
              _ -> nil
            end

          %{id: prereq_id, title: title}
        end)

      {:error,
       "objective #{inspect(objective["id"])} is locked by unmet prerequisites " <>
         "(missing: #{inspect(missing)}); master prerequisites first — locked objectives cannot be evaluated"}
    end
  end

  # --- 落库 + 即时完成判定 + 响应投影 ---------------------------------------------

  # attempt 落库与完成判定刻意非同事务(见 moduledoc):账本为真源,
  # completion 失败(乐观锁竞态等)只记日志,5 分钟 worker 兜底收敛。
  defp record_attempt(
         _actor,
         workspace_id,
         run,
         revision,
         objective,
         objectives,
         prior_attempts,
         attrs
       ) do
    case create_attempt(workspace_id, run, revision, attrs) do
      {:ok, attempt} ->
        completion = complete_safely(run)
        all_attempts = prior_attempts ++ [attempt]
        new_states = Mastery.states(all_attempts, objectives)
        entry = Map.get(new_states, objective["id"], %{})

        {:ok,
         %{
           attempt_id: attempt.id,
           mastery: to_string(Map.get(entry, :state, :unassessed)),
           ever_mastered: Map.get(entry, :ever_mastered, false),
           run_completed: completion == :completed,
           next_action: serialize_next_action(NextAction.next(objectives, new_states, []))
         }}

      {:error, %Ash.Error.Invalid{} = error} ->
        {:error, Exception.message(error)}

      {:error, error} ->
        {:error, "failed to record learning attempt: #{inspect(error)}"}
    end
  end

  # 唯一写入口(工具层授权 + 校验链已过):authorize?: false 系统效应,
  # 同 CourseRevision 发布步纪律
  defp create_attempt(workspace_id, run, revision, attrs) do
    Attempt
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(attrs, %{
        learning_run_id: run.id,
        course_revision_id: revision.id
      }),
      tenant: workspace_id,
      authorize?: false
    )
    |> Ash.create(tenant: workspace_id, authorize?: false)
  end

  defp complete_safely(run) do
    case Runs.complete_when_mastered(run) do
      {:ok, outcome, _run} ->
        outcome

      {:error, reason} ->
        Logger.warning(
          "submit_learning_attempt: completion check failed for run #{run.id}: #{inspect(reason)}"
        )

        :incomplete
    end
  end

  defp serialize_next_action(nil), do: nil

  defp serialize_next_action(%{kind: kind} = action) do
    %{action | kind: to_string(kind)}
  end
end
