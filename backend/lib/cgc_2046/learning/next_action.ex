defmodule Cgc2046.Learning.NextAction do
  @moduledoc """
  下一动作推荐(role-agent-journeys-v2 S8,R40/R41;ADR-0011 L5):纯函数,无 IO。

  输入 = 某 revision 内容的 objectives(内容序,`Curriculum.Content.objectives/1`
  平铺结果)+ `Mastery.states/2` 投影 + 复习到期队列(**S8 恒 []**——
  ReviewSchedule 与真实队列属 S9,`next/3` 第三参保留默认签名,
  review 分支结构在位等接通)。

  返回 `%{kind, objective_id, reason}` 或 nil(课程完成)。reason 是含
  objective title 的中文句——playbook 要求 agent 按 reason 向学员解释起点。

  **完成守卫先行**:`Mastery.all_required_ever_mastered?/2` 为 true 即
  返回 nil(complete),不再推荐任何动作(即使选修未做、复习到期——AE10:
  完成结果不被复习翻转撤销)。

  优先级(R40):

  1. `:review` — 复习到期队列非空,取队首 objective(S9 起真实队列:
     间隔重复 1/7/30 天到期 + needs_review 立即到期,R45;needs_review
     条目 reason 明示「待复习」);
  2. `:remediation` — 当前 developing objective(last_attempt_at 最新者)的
     先修中有 `:needs_review` 者,按 prereq_ids 序取首个——先回补 regress 的
     先修再继续;
  3. `:developing` — 继续当前 developing objective;
  4. `:next_required` — 内容序首个「必修 ∧ unassessed ∧ 已解锁」;
  5. `:elective` — 内容序首个「选修 ∧ 已解锁 ∧ 非 ever_mastered」。

  **锁定纪律(R41)**:`unlocked?/2` = 全部 prereq_ids ever_mastered;锁定的
  objective 不被推荐,submit 工具同样拒绝评价(不可绕过),缺失先修由
  `missing_prereq_ids/2` 列出。
  """

  alias Cgc2046.Curriculum.Content
  alias Cgc2046.Learning.Mastery

  @typedoc "下一动作推荐"
  @type t :: %{
          kind: :review | :remediation | :developing | :next_required | :elective,
          objective_id: String.t(),
          reason: String.t()
        }

  @doc """
  下一动作推荐(R40 优先级;完成守卫先行,全必修 ever_mastered → nil)。
  """
  @spec next([map()], %{String.t() => Mastery.state_entry()}, [map()]) ::
          t() | nil
  def next(objectives, states, review_queue \\ [])
      when is_list(objectives) and is_map(states) and is_list(review_queue) do
    if Mastery.all_required_ever_mastered?(states, objectives) do
      nil
    else
      review(review_queue, objectives) ||
        remediation_or_developing(objectives, states) ||
        next_required(objectives, states) ||
        elective(objectives, states)
    end
  end

  @doc "objective 是否已解锁(R41):全部 prereq_ids ever_mastered。"
  @spec unlocked?(map(), %{String.t() => Mastery.state_entry()}) :: boolean()
  def unlocked?(objective, states) when is_map(objective) and is_map(states) do
    objective
    |> prereq_ids()
    |> Enum.all?(&Mastery.ever_mastered?(states, &1))
  end

  @doc "未 ever_mastered 的先修 objective id 列表(prereq_ids 序,R41 拒评时列出)。"
  @spec missing_prereq_ids(map(), %{String.t() => Mastery.state_entry()}) :: [String.t()]
  def missing_prereq_ids(objective, states) when is_map(objective) and is_map(states) do
    objective
    |> prereq_ids()
    |> Enum.reject(&Mastery.ever_mastered?(states, &1))
  end

  # --- 私有实现 ----------------------------------------------------------------

  # ① 复习到期队列(S9 起由 ReviewSchedule 派生):队首 objective 仍在内容中
  # 才推荐;needs_review 条目(复习失败)reason 明示「待复习」
  defp review(review_queue, objectives) do
    with [%{objective_id: objective_id} = entry | _] <- review_queue,
         %{"id" => _, "title" => title} <- find(objectives, objective_id) do
      %{
        kind: :review,
        objective_id: objective_id,
        reason: review_reason(title, Map.get(entry, :needs_review, false))
      }
    else
      _ -> nil
    end
  end

  defp review_reason(title, true),
    do: "「#{title}」上次复习未通过(待复习),先重新巩固——再次正式评价合格即恢复掌握"

  defp review_reason(title, false),
    do: "「#{title}」到了复习时间,先做一次回顾练习巩固掌握"

  # ②③ 当前 developing(last_attempt_at 最新):先修有 needs_review → 回补先修;
  # 否则继续该 developing
  defp remediation_or_developing(objectives, states) do
    case current_developing(objectives, states) do
      nil ->
        nil

      current ->
        case regressed_prereq(current, objectives, states) do
          %{"id" => prereq_id, "title" => prereq_title} ->
            %{
              kind: :remediation,
              objective_id: prereq_id,
              reason:
                "继续「#{current["title"]}」前,先回补先修「#{prereq_title}」——" <>
                  "上次掌握后复习未通过,需要重新巩固"
            }

          nil ->
            %{
              kind: :developing,
              objective_id: current["id"],
              reason: "继续攻克「#{current["title"]}」——已有尝试但尚未达到掌握标准"
            }
        end
    end
  end

  # ④ 内容序首个 必修 ∧ unassessed ∧ 已解锁
  defp next_required(objectives, states) do
    objectives
    |> Enum.filter(fn objective ->
      Content.required_objective?(objective) and
        state_of(states, objective["id"]) == :unassessed and
        unlocked?(objective, states)
    end)
    |> case do
      [objective | _] ->
        %{
          kind: :next_required,
          objective_id: objective["id"],
          reason: "下一个必修目标是「#{objective["title"]}」,从这里开始"
        }

      [] ->
        nil
    end
  end

  # ⑤ 内容序首个 选修 ∧ 已解锁 ∧ 非 ever_mastered
  defp elective(objectives, states) do
    objectives
    |> Enum.filter(fn objective ->
      not Content.required_objective?(objective) and
        unlocked?(objective, states) and
        not Mastery.ever_mastered?(states, objective["id"])
    end)
    |> case do
      [objective | _] ->
        %{
          kind: :elective,
          objective_id: objective["id"],
          reason: "必修已全部完成,可以挑战选修目标「#{objective["title"]}」"
        }

      [] ->
        nil
    end
  end

  # 当前 developing = 有 attempt 未 qualifying 的 objective 中 last_attempt_at 最新者
  # (并列时取内容序靠前者——最近活跃的优先)
  defp current_developing(objectives, states) do
    objectives
    |> Enum.filter(fn objective -> state_of(states, objective["id"]) == :developing end)
    |> Enum.max_by(
      fn objective -> Map.get(states, objective["id"], %{}) |> Map.get(:last_attempt_at) end,
      &later?/2,
      fn -> nil end
    )
  end

  # 当前 objective 的 prereq_ids 序首个 needs_review 先修
  defp regressed_prereq(current, objectives, states) do
    current
    |> prereq_ids()
    |> Enum.find_value(fn prereq_id ->
      if state_of(states, prereq_id) == :needs_review, do: find(objectives, prereq_id)
    end)
  end

  defp state_of(states, objective_id) do
    case Map.get(states, objective_id) do
      %{state: state} -> state
      _ -> :unassessed
    end
  end

  defp find(objectives, objective_id) do
    Enum.find(objectives, fn
      %{"id" => id} -> id == objective_id
      _ -> false
    end)
  end

  defp prereq_ids(objective) do
    case objective["prereq_ids"] do
      ids when is_list(ids) -> Enum.filter(ids, &is_binary/1)
      _ -> []
    end
  end

  # max_by sorter(语义:sorter(new, current) 为 true → new 取代 current):
  # 严格更晚才取代(并列保留内容序靠前者);nil 视为最小(防御性,
  # developing 必有 last_attempt_at)
  defp later?(nil, _current), do: false
  defp later?(_new, nil), do: true
  defp later?(new, current), do: DateTime.compare(new, current) == :gt
end
