defmodule Cgc2046.Learning.ReviewScheduleTest do
  @moduledoc """
  ReviewSchedule 纯函数测试(S9,R45):1/7/30 里程碑锚定首次掌握 / 按序消费
  (含锚点前提与迟到复习)/ 失败复习不消费 / needs_review 恒立即到期 /
  非掌握 objective 永不入队。纯函数,无 DB——时间全部注入。
  """
  use ExUnit.Case, async: true

  alias Cgc2046.Learning.ReviewSchedule

  # 首次掌握时间锚点
  @t0 ~U[2026-08-01 10:00:00Z]

  # obj-a:必修,rubric 两条(r1/r2);obj-b:必修,rubric 单条
  defp objectives do
    [
      %{
        "id" => "obj-a",
        "title" => "目标 A",
        "required" => true,
        "prereq_ids" => [],
        "rubric" => [%{"id" => "r1"}, %{"id" => "r2"}]
      },
      %{
        "id" => "obj-b",
        "title" => "目标 B",
        "required" => true,
        "prereq_ids" => [],
        "rubric" => [%{"id" => "r1"}]
      }
    ]
  end

  defp rubric_a, do: [%{criterion_id: "r1", met: true}, %{criterion_id: "r2", met: true}]

  defp qualifying_a(at), do: attempt("obj-a", at, rubric_results: rubric_a())
  defp failed_a(at), do: attempt("obj-a", at, passed: false)

  defp attempt(objective_id, created_at, opts \\ []) do
    %{
      objective_id: objective_id,
      passed: Keyword.get(opts, :passed, true),
      confidence: Keyword.get(opts, :confidence, 0.9),
      rubric_results: Keyword.get(opts, :rubric_results, [%{criterion_id: "r1", met: true}]),
      created_at: created_at
    }
  end

  defp days_after(days), do: DateTime.add(@t0, days, :day)

  describe "due/3 里程碑到期" do
    test "首次掌握后里程碑未到 → 空队列(fresh mastery)" do
      assert ReviewSchedule.due([qualifying_a(@t0)], objectives(), @t0) == []

      assert ReviewSchedule.due(
               [qualifying_a(@t0)],
               objectives(),
               days_after(1) |> DateTime.add(-1, :second)
             ) == []
    end

    test "day+1 → +1d 里程碑到期(due_at = first_mastered_at + 1 天)" do
      [entry] = ReviewSchedule.due([qualifying_a(@t0)], objectives(), days_after(1))

      assert entry.objective_id == "obj-a"
      assert entry.due_at == days_after(1)
      assert entry.milestone_days == 1
      assert entry.needs_review == false
    end

    test "day+7 无复习 → 仍只挂 +1d 里程碑(不跳档)" do
      [entry] = ReviewSchedule.due([qualifying_a(@t0)], objectives(), days_after(7))

      assert entry.milestone_days == 1
      assert entry.due_at == days_after(1)
    end

    test "qualifying 复习按序消费:+1d 复习后 +7d 到期;+7d 复习后 +30d 到期" do
      review_1 = qualifying_a(days_after(2))
      attempts = [qualifying_a(@t0), review_1]

      # 第 1 条复习消费 +1d;+7d 未到 → 空
      assert ReviewSchedule.due(attempts, objectives(), days_after(2)) == []

      # +7d 到 → 挂 +7d 里程碑
      assert [%{milestone_days: 7, due_at: due_at}] =
               ReviewSchedule.due(attempts, objectives(), days_after(7))

      assert due_at == days_after(7)

      # 第 2 条复习(day 8,晚于 +1d 锚点)消费 +7d → 下一里程碑 +30d
      attempts2 = attempts ++ [qualifying_a(days_after(8))]
      assert ReviewSchedule.due(attempts2, objectives(), days_after(29)) == []

      assert [%{milestone_days: 30, due_at: due_at2}] =
               ReviewSchedule.due(attempts2, objectives(), days_after(30))

      assert due_at2 == days_after(30)
    end

    test "锚点前提:紧贴掌握的突击复习不消费下一里程碑" do
      # 两条复习都在 day+1 锚点之前:第 1 条消费 +1d(上一锚点 = 掌握时刻),
      # 第 2 条早于 +1d 锚点 → 不消费 +7d
      attempts = [
        qualifying_a(@t0),
        qualifying_a(DateTime.add(@t0, 3600, :second)),
        qualifying_a(DateTime.add(@t0, 7200, :second))
      ]

      assert [%{milestone_days: 7}] = ReviewSchedule.due(attempts, objectives(), days_after(7))
    end

    test "迟到复习仍按序消费:day 40 首条复习只消费 +1d,+7d 随即可补" do
      attempts = [qualifying_a(@t0), qualifying_a(days_after(40))]

      # +1d 被迟到消费;+7d 里程碑(due_at 早已过)立即可补
      assert [%{milestone_days: 7, due_at: due_at}] =
               ReviewSchedule.due(attempts, objectives(), days_after(40))

      assert due_at == days_after(7)
    end

    test "三个里程碑全满足 → 永不到期" do
      attempts = [
        qualifying_a(@t0),
        qualifying_a(days_after(2)),
        qualifying_a(days_after(8)),
        qualifying_a(days_after(31))
      ]

      assert ReviewSchedule.due(attempts, objectives(), days_after(365)) == []
    end

    test "非掌握 objective 永不入队(unassessed / developing)" do
      assert ReviewSchedule.due([], objectives(), days_after(365)) == []
      assert ReviewSchedule.due([failed_a(@t0)], objectives(), days_after(365)) == []
    end

    test "多 objective 按 due_at 升序" do
      # obj-b 掌握于 day 5(→ 到期 day 6),obj-a 掌握于 day 0(→ 到期 day 1)
      attempts = [qualifying_a(@t0), attempt("obj-b", days_after(5))]

      assert [%{objective_id: "obj-a"}, %{objective_id: "obj-b"}] =
               ReviewSchedule.due(attempts, objectives(), days_after(6))
    end
  end

  describe "due/3 needs_review(R45/AE10)" do
    test "复习失败 → needs_review 恒立即到期(due_at = 失败 attempt 时间,带 flag)" do
      failed_at = days_after(2)
      attempts = [qualifying_a(@t0), failed_a(failed_at)]

      [entry] = ReviewSchedule.due(attempts, objectives(), failed_at)

      assert entry.objective_id == "obj-a"
      assert entry.needs_review == true
      assert entry.due_at == failed_at
      # 下一个未满足里程碑 = +1d(失败复习不消费)
      assert entry.milestone_days == 1
    end

    test "失败复习不满足任何里程碑;再次 qualifying 恢复 mastered 并消费" do
      attempts = [qualifying_a(@t0), failed_a(days_after(2))]

      # 失败时:needs_review 立即到期
      assert [%{needs_review: true}] = ReviewSchedule.due(attempts, objectives(), days_after(2))

      # 再次 qualifying(day 3):恢复 mastered,该条消费 +1d 里程碑
      recovered = attempts ++ [qualifying_a(days_after(3))]
      assert ReviewSchedule.due(recovered, objectives(), days_after(3)) == []

      assert [%{milestone_days: 7, needs_review: false}] =
               ReviewSchedule.due(recovered, objectives(), days_after(7))
    end

    test "里程碑全消费后再失败 → 仍立即到期,milestone_days = nil" do
      attempts = [
        qualifying_a(@t0),
        qualifying_a(days_after(2)),
        qualifying_a(days_after(8)),
        qualifying_a(days_after(31)),
        failed_a(days_after(40))
      ]

      [entry] = ReviewSchedule.due(attempts, objectives(), days_after(40))

      assert entry.needs_review == true
      assert entry.due_at == days_after(40)
      assert entry.milestone_days == nil
    end

    test "needs_review 条目与到期里程碑并存时按 due_at 升序" do
      # obj-a:掌握 day 0,掌握后 1 小时复习失败(needs_review,due_at = 失败时刻);
      # obj-b:掌握 day 0,+1d 里程碑到期(due_at = day 1)——obj-a 失败更早 → 排前
      failed_at = DateTime.add(@t0, 3600, :second)
      attempts = [qualifying_a(@t0), failed_a(failed_at), attempt("obj-b", @t0)]

      assert [%{objective_id: "obj-a", needs_review: true}, %{objective_id: "obj-b"}] =
               ReviewSchedule.due(attempts, objectives(), days_after(2))
    end
  end
end
