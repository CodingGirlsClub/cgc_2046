defmodule Cgc2046.Learning.Mastery do
  @moduledoc """
  掌握状态投影(role-agent-journeys-v2 S8,R43;ADR-0011 L2):纯函数,无 IO。

  输入 = 一个学习 run 的不可变 LearningAttempt 列表 + 其绑定 revision 内容的
  objectives(`Cgc2046.Curriculum.Content.objectives/1` 平铺结果)。
  **agent 永不直写 mastery**——掌握四态由本模块从 attempts 派生:

  - `:unassessed` — 无任何 attempt;
  - `:developing` — 有 attempt,无一条 qualifying;
  - `:mastered` — **最新** attempt qualifying(S9 起 latest-attempt-driven:
    失败后再次 qualifying 即恢复 mastered——needs_review 可恢复,R45);
  - `:needs_review` — 曾 qualifying,但**最新** attempt 失败(掌握后复习
    失败,R45 hook;`ever_mastered` 仍为 true——完成判定不因此倒退,AE10)。

  **qualifying 判据**(单源 `qualifying?/2`):
  `passed == true` 且 `confidence >= 0.8`(`confidence_floor/0`)且
  `rubric_results` 精确覆盖 objective rubric 全部 criterion id 且逐条
  `met == true`。

  **失败 attempt**(needs_review 转换语义)= 任何非 qualifying 的 attempt
  (passed=false,或置信度不足,或 rubric 未全达标)。状态只看**最新一条**
  attempt:最新 qualifying → mastered;最新失败 → 曾 qualifying 则
  needs_review,否则 developing(S9 恢复语义:needs_review 经再次正式
  评价合格即恢复 mastered,`first_mastered_at` 不变)。

  完成判定(R39/AE10)用 `ever_mastered` 而非当前状态:needs_review 仍计完成。
  `all_required_ever_mastered?/2` 是 run 完成的唯一判据(必修集为空 → false,
  防空内容误判完成)。

  attempt 入参兼容 LearningAttempt struct 与 plain map(atom 或 string 键),
  便于纯函数测试;objective 为内容 JSON(string 键)。
  """

  alias Cgc2046.Curriculum.Content

  @confidence_floor 0.8

  @doc "qualifying 置信度下限(R43:< 0.8 不构成掌握)。"
  def confidence_floor, do: @confidence_floor

  @typedoc "objective 掌握状态条目"
  @type state_entry :: %{
          state: :unassessed | :developing | :mastered | :needs_review,
          ever_mastered: boolean(),
          attempt_count: non_neg_integer(),
          last_attempt_at: DateTime.t() | nil,
          first_mastered_at: DateTime.t() | nil
        }

  @doc """
  qualifying 判定:passed ∧ confidence ≥ 0.8 ∧ rubric 精确覆盖且全 met(R43)。
  """
  @spec qualifying?(term(), map()) :: boolean()
  def qualifying?(attempt, objective) do
    field(attempt, :passed) == true and
      confidence_qualifying?(field(attempt, :confidence)) and
      rubric_all_met?(field(attempt, :rubric_results), objective)
  end

  @doc """
  rubric 精确覆盖校验(submit 工具与本模块共用):提交的 criterion id 集合 ==
  objective rubric 的 criterion id 集合(不多不少;重复提交同一 id 视为不精确)。
  """
  @spec rubric_exact?(term(), map()) :: boolean()
  def rubric_exact?(rubric_results, objective) when is_list(rubric_results) do
    submitted = criterion_ids(rubric_results)
    expected = rubric_criterion_ids(objective)

    length(submitted) == length(expected) and
      MapSet.equal?(MapSet.new(submitted), MapSet.new(expected))
  end

  def rubric_exact?(_rubric_results, _objective), do: false

  @doc """
  全 objectives 的掌握投影:`%{objective_id => state_entry}`。

  attempts 按 created_at 升序逐 objective 归组;objective 无 attempt 时
  `state: :unassessed, attempt_count: 0, last_attempt_at: nil, first_mastered_at: nil`。
  """
  @spec states([term()], [map()]) :: %{String.t() => state_entry()}
  def states(attempts, objectives) when is_list(attempts) and is_list(objectives) do
    grouped =
      attempts
      |> Enum.group_by(&field(&1, :objective_id))

    Map.new(objectives, fn objective ->
      {objective["id"], state_entry(objective, grouped)}
    end)
  end

  @doc """
  ever_mastered 粘性查询(R39/AE10 完成判定谓词):曾达 qualifying 即 true,
  当前状态为 needs_review 不影响。states 缺该 objective 条目 → false。
  """
  @spec ever_mastered?(%{String.t() => state_entry()}, String.t()) :: boolean()
  def ever_mastered?(states, objective_id) when is_map(states) do
    case Map.get(states, objective_id) do
      %{ever_mastered: true} -> true
      _ -> false
    end
  end

  @doc """
  run 完成判据(R39):全部**必修** objective ever_mastered;必修集为空 →
  false(无必修的内容不构成可完成的学习闭环,防误判)。
  """
  @spec all_required_ever_mastered?(%{String.t() => state_entry()}, [map()]) :: boolean()
  def all_required_ever_mastered?(states, objectives) when is_list(objectives) do
    required = Enum.filter(objectives, &Content.required_objective?/1)

    required != [] and Enum.all?(required, &ever_mastered?(states, &1["id"]))
  end

  # --- 私有实现 ----------------------------------------------------------------

  defp state_entry(objective, grouped) do
    objective
    |> attempts_for(grouped)
    |> build_entry(objective)
  end

  # 该 objective 的 attempts 按 created_at 升序(nil 排最前——防御性,正常不存在)
  defp attempts_for(objective, grouped) do
    (Map.get(grouped, objective["id"]) || [])
    |> Enum.sort_by(&field(&1, :created_at), &compare_time/2)
  end

  defp build_entry([], _objective) do
    %{
      state: :unassessed,
      ever_mastered: false,
      attempt_count: 0,
      last_attempt_at: nil,
      first_mastered_at: nil
    }
  end

  defp build_entry(attempts, objective) do
    latest = List.last(attempts)

    %{
      attempt_count: length(attempts),
      last_attempt_at: field(latest, :created_at)
    }
    |> Map.merge(mastery_fields(attempts, latest, objective))
  end

  # S9 起「最新 attempt 驱动」(R45 恢复语义):无任何 qualifying → developing;
  # 最新 qualifying → mastered(ever_mastered 粘性,first_mastered_at 锚定首条
  # qualifying);最新失败且曾 qualifying → needs_review
  defp mastery_fields(attempts, latest, objective) do
    case Enum.find(attempts, &qualifying?(&1, objective)) do
      nil ->
        %{state: :developing, ever_mastered: false, first_mastered_at: nil}

      first_qualifying ->
        first_mastered_at = field(first_qualifying, :created_at)

        if qualifying?(latest, objective) do
          %{state: :mastered, ever_mastered: true, first_mastered_at: first_mastered_at}
        else
          %{state: :needs_review, ever_mastered: true, first_mastered_at: first_mastered_at}
        end
    end
  end

  defp compare_time(nil, _b), do: true
  defp compare_time(_a, nil), do: false
  defp compare_time(a, b), do: DateTime.compare(a, b) != :gt

  defp confidence_qualifying?(confidence) when is_number(confidence),
    do: confidence >= @confidence_floor

  defp confidence_qualifying?(_confidence), do: false

  # rubric 全达标 = 精确覆盖 + 逐条 met == true
  defp rubric_all_met?(rubric_results, objective) do
    rubric_exact?(rubric_results, objective) and
      Enum.all?(rubric_results, fn result -> field(result, :met) == true end)
  end

  defp criterion_ids(rubric_results) do
    Enum.flat_map(rubric_results, fn
      result when is_map(result) ->
        case field(result, :criterion_id) do
          id when is_binary(id) -> [id]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp rubric_criterion_ids(objective) when is_map(objective) do
    case objective["rubric"] do
      rubric when is_list(rubric) ->
        Enum.flat_map(rubric, fn
          %{"id" => id} when is_binary(id) -> [id]
          _ -> []
        end)

      _ ->
        []
    end
  end

  defp rubric_criterion_ids(_objective), do: []

  # 字段读取:atom 键优先,string 键兜底(false/nil 不吞——Map.fetch 语义)
  defp field(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_other, _key), do: nil
end
