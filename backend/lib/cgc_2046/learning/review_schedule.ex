defmodule Cgc2046.Learning.ReviewSchedule do
  @moduledoc """
  间隔重复复习调度(role-agent-journeys-v2 S9,R45;ADR-0011 L4):**纯函数,无 IO、
  不建表**——复习到期视图由 attempts 投影即时派生。

  objective 首次掌握(首条 qualifying attempt,即 `Mastery` 投影的
  `first_mastered_at`)后进入复习队列,里程碑 = 首次掌握起 **+1 / +7 / +30 天**
  (`intervals/0`)。

  **按序消费**:第 n 条「掌握后 qualifying attempt」(created_at 严格晚于
  `first_mastered_at`——首条 qualifying 是掌握本身,不算复习)满足第 n 个
  里程碑,前提是该 attempt 晚于**上一个里程碑的锚点**(第 1 个里程碑的上一个
  锚点 = `first_mastered_at` 本身)——不能一次突击刷掉全部里程碑。迟到复习
  照常计入(第 40 天的首条复习仍只消费 +1d 里程碑);**失败复习不满足任何
  里程碑**。三个里程碑全满足后该 objective 不再到期。

  **needs_review 即到期**:最新 attempt 失败(Mastery 投影 `needs_review`)的
  objective 恒立即到期——条目 `due_at` = 失败 attempt 的 created_at(=
  state entry 的 `last_attempt_at`),`needs_review: true`,`milestone_days` =
  下一个未满足里程碑;里程碑已全部消费后再失败 → `milestone_days: nil`
  (无里程碑可重做,条目语义 = 「再次正式评价合格以恢复 mastered」)。

  `due/3` 返回 `%{objective_id, due_at, milestone_days, needs_review}` 列表,
  按 `due_at` 升序;**时间全部由调用方注入**(纯函数纪律)。

  **完成不撤销(AE10)与完成后边界(v1 决策)**:本模块只派生复习到期视图;
  run 完成判定仍只看 `ever_mastered`,复习失败翻转为 needs_review **不撤销**
  已产出的 LearningRun 完成结果。已 succeeded 的 run 不接受新 attempt
  (submit 要求非终态 run),因此**完成后的复习无提交通道,v1 刻意不做**——
  needs_review 语义作用于仍在进行中的 run(某 objective 已掌握、复习失败时
  其他必修尚未完成);完成后的复习调度留待后续切片(需完成后复习通道的
  产品决策)。
  """

  alias Cgc2046.Learning.Mastery

  @intervals [1, 7, 30]

  @typedoc "复习到期队列条目"
  @type queue_entry :: %{
          objective_id: String.t(),
          due_at: DateTime.t(),
          milestone_days: pos_integer() | nil,
          needs_review: boolean()
        }

  @doc "复习里程碑(天,锚定首次掌握时间,按序消费)。"
  def intervals, do: @intervals

  @doc """
  到期复习队列(R45):曾掌握(ever_mastered)objective 中,needs_review 者
  恒立即到期,其余在下一个未满足里程碑 `due_at <= now` 时到期;按 due_at
  升序。从未掌握的 objective 永不入队。
  """
  @spec due([term()], [map()], DateTime.t()) :: [queue_entry()]
  def due(attempts, objectives, now) when is_list(attempts) and is_list(objectives) do
    states = Mastery.states(attempts, objectives)
    grouped = Enum.group_by(attempts, &field(&1, :objective_id))

    objectives
    |> Enum.flat_map(fn objective ->
      case Map.get(states, objective["id"]) do
        %{ever_mastered: true, first_mastered_at: %DateTime{} = first_mastered_at} = entry ->
          satisfied =
            objective
            |> qualifying_review_ats(Map.get(grouped, objective["id"], []), first_mastered_at)
            |> consumed_count(first_mastered_at)

          due_entry(objective["id"], entry, first_mastered_at, satisfied, now)

        _ ->
          []
      end
    end)
    |> Enum.sort_by(& &1.due_at, &(DateTime.compare(&1, &2) != :gt))
  end

  # needs_review → 恒立即到期(due_at = 失败 attempt 的 created_at = last_attempt_at,
  # needs_review 态下最新 attempt 即失败的那条)
  defp due_entry(
         objective_id,
         %{state: :needs_review, last_attempt_at: %DateTime{} = failed_at},
         _first_mastered_at,
         satisfied,
         _now
       ) do
    [
      %{
        objective_id: objective_id,
        due_at: failed_at,
        milestone_days: next_milestone_days(satisfied),
        needs_review: true
      }
    ]
  end

  # mastered:下一个未满足里程碑到期即入队;全满足 → 不入队
  defp due_entry(objective_id, _entry, first_mastered_at, satisfied, now) do
    case next_milestone_days(satisfied) do
      nil ->
        []

      days ->
        due_at = DateTime.add(first_mastered_at, days, :day)

        if DateTime.compare(due_at, now) != :gt do
          [
            %{
              objective_id: objective_id,
              due_at: due_at,
              milestone_days: days,
              needs_review: false
            }
          ]
        else
          []
        end
    end
  end

  defp next_milestone_days(satisfied) when satisfied < length(@intervals),
    do: Enum.at(@intervals, satisfied)

  defp next_milestone_days(_satisfied), do: nil

  # 掌握后 qualifying attempt 的 created_at 升序(严格晚于 first_mastered_at)
  defp qualifying_review_ats(objective, attempts, first_mastered_at) do
    attempts
    |> Enum.filter(fn attempt ->
      Mastery.qualifying?(attempt, objective) and
        later?(field(attempt, :created_at), first_mastered_at)
    end)
    |> Enum.map(&field(&1, :created_at))
    |> Enum.sort(&(DateTime.compare(&1, &2) != :gt))
  end

  # 按序消费:一条复习 attempt 满足「下一个未满足里程碑」的前提 = 晚于上一个
  # 里程碑锚点(第 1 个的上一个锚点 = first_mastered_at);不满足前提的 attempt
  # 不消费任何里程碑(太接近掌握的突击复习不计入下一里程碑)
  defp consumed_count(review_ats, first_mastered_at) do
    Enum.reduce(review_ats, 0, fn at, satisfied ->
      if satisfied < length(@intervals) and
           DateTime.compare(at, previous_anchor(first_mastered_at, satisfied)) == :gt do
        satisfied + 1
      else
        satisfied
      end
    end)
  end

  defp previous_anchor(first_mastered_at, 0), do: first_mastered_at

  defp previous_anchor(first_mastered_at, satisfied) do
    DateTime.add(first_mastered_at, Enum.at(@intervals, satisfied - 1), :day)
  end

  defp later?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :gt
  defp later?(_a, _b), do: false

  # 字段读取:atom 键优先,string 键兜底(与 Mastery 字段读取同语义——纯函数
  # 测试直传 plain map,生产路径为 LearningAttempt struct)
  defp field(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_other, _key), do: nil
end
