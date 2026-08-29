defmodule Cgc2046.Learning.MasteryTest do
  @moduledoc """
  Mastery 纯投影测试(S8,R43/R39;S9 latest-attempt-driven 恢复语义,R45):
  qualifying 判据 / 四态转换(含 needs_review 恢复)/ ever_mastered 粘性 /
  完成判据。纯函数,无 DB。
  """
  use ExUnit.Case, async: true

  alias Cgc2046.Learning.Mastery

  @t0 ~U[2026-08-01 10:00:00Z]

  # obj-a:必修,rubric 两条(r1/r2);obj-b:必修,先修 obj-a,rubric 单条;
  # obj-c:选修,rubric 单条
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
        "prereq_ids" => ["obj-a"],
        "rubric" => [%{"id" => "r1"}]
      },
      %{
        "id" => "obj-c",
        "title" => "目标 C(选修)",
        "required" => false,
        "prereq_ids" => [],
        "rubric" => [%{"id" => "r1"}]
      }
    ]
  end

  defp attempt(objective_id, created_at, opts \\ []) do
    %{
      objective_id: objective_id,
      passed: Keyword.get(opts, :passed, true),
      confidence: Keyword.get(opts, :confidence, 0.9),
      rubric_results: Keyword.get(opts, :rubric_results, [%{criterion_id: "r1", met: true}]),
      created_at: created_at
    }
  end

  # obj-a 的 qualifying 标配:r1+r2 精确覆盖且全 met
  defp rubric_a, do: [%{criterion_id: "r1", met: true}, %{criterion_id: "r2", met: true}]

  defp qualifying_a(at), do: attempt("obj-a", at, rubric_results: rubric_a())

  describe "qualifying?/2(R43 判据单源)" do
    test "passed ∧ confidence ≥ 0.8 ∧ rubric 精确覆盖全 met → true" do
      assert Mastery.qualifying?(qualifying_a(@t0), hd(objectives()))
    end

    test "passed=false 不 qualifying(其余条件再好也没用)" do
      refute Mastery.qualifying?(
               attempt("obj-a", @t0, passed: false, rubric_results: rubric_a()),
               hd(objectives())
             )
    end

    test "confidence 边界:0.79 不 qualifying,0.8 qualifying" do
      objective = hd(objectives())

      refute Mastery.qualifying?(
               attempt("obj-a", @t0, confidence: 0.79, rubric_results: rubric_a()),
               objective
             )

      assert Mastery.qualifying?(
               attempt("obj-a", @t0, confidence: 0.8, rubric_results: rubric_a()),
               objective
             )
    end

    test "rubric 缺条 / 多条 / 重复 id / 未全 met 均不 qualifying" do
      objective = hd(objectives())

      # 缺 r2
      refute Mastery.qualifying?(
               attempt("obj-a", @t0, rubric_results: [%{criterion_id: "r1", met: true}]),
               objective
             )

      # 多 r3
      refute Mastery.qualifying?(
               attempt("obj-a", @t0,
                 rubric_results: rubric_a() ++ [%{criterion_id: "r3", met: true}]
               ),
               objective
             )

      # 重复 r1(长度对上但集合不对)
      refute Mastery.qualifying?(
               attempt("obj-a", @t0,
                 rubric_results: [
                   %{criterion_id: "r1", met: true},
                   %{criterion_id: "r1", met: true}
                 ]
               ),
               objective
             )

      # r2 未 met
      refute Mastery.qualifying?(
               attempt("obj-a", @t0,
                 rubric_results: [
                   %{criterion_id: "r1", met: true},
                   %{criterion_id: "r2", met: false}
                 ]
               ),
               objective
             )
    end

    test "string 键 attempt / rubric_results map 兼容" do
      attempt = %{
        "objective_id" => "obj-b",
        "passed" => true,
        "confidence" => 0.85,
        "rubric_results" => [%{"criterion_id" => "r1", "met" => true}],
        "created_at" => @t0
      }

      assert Mastery.qualifying?(attempt, Enum.at(objectives(), 1))
    end
  end

  describe "rubric_exact?/2(精确覆盖)" do
    test "集合相等 + 长度相等 → true;否则 false" do
      objective = hd(objectives())

      assert Mastery.rubric_exact?(
               [%{"criterion_id" => "r2"}, %{"criterion_id" => "r1"}],
               objective
             )

      refute Mastery.rubric_exact?([%{"criterion_id" => "r1"}], objective)
      refute Mastery.rubric_exact?([], objective)
      refute Mastery.rubric_exact?(nil, objective)
    end
  end

  describe "states/2 四态投影" do
    test "无 attempt → 全 unassessed,计数与时间字段为零值" do
      states = Mastery.states([], objectives())

      assert map_size(states) == 3

      assert states["obj-a"] == %{
               state: :unassessed,
               ever_mastered: false,
               attempt_count: 0,
               last_attempt_at: nil,
               first_mastered_at: nil
             }
    end

    test "仅失败 attempt → developing(ever_mastered false)" do
      states = Mastery.states([attempt("obj-a", @t0, passed: false)], objectives())
      entry = states["obj-a"]

      assert entry.state == :developing
      assert entry.ever_mastered == false
      assert entry.attempt_count == 1
      assert entry.last_attempt_at == @t0
      assert entry.first_mastered_at == nil
    end

    test "qualifying attempt → mastered(first_mastered_at = 首条 qualifying 时间)" do
      states = Mastery.states([qualifying_a(@t0)], objectives())
      entry = states["obj-a"]

      assert entry.state == :mastered
      assert entry.ever_mastered == true
      assert entry.first_mastered_at == @t0
      assert entry.last_attempt_at == @t0
    end

    test "mastered 后出现失败 attempt → needs_review,ever_mastered 仍 true(R45/AE10)" do
      t1 = @t0
      t2 = DateTime.add(@t0, 3600, :second)

      attempts = [qualifying_a(t1), attempt("obj-a", t2, passed: false)]
      states = Mastery.states(attempts, objectives())
      entry = states["obj-a"]

      assert entry.state == :needs_review
      assert entry.ever_mastered == true
      assert entry.attempt_count == 2
      assert entry.first_mastered_at == t1
      assert entry.last_attempt_at == t2
    end

    test "attempts 乱序传入按 created_at 升序投影" do
      t1 = @t0
      t2 = DateTime.add(@t0, 3600, :second)

      # 列表顺序与时间序相反,投影结果不变
      attempts = [attempt("obj-a", t2, passed: false), qualifying_a(t1)]
      states = Mastery.states(attempts, objectives())

      assert states["obj-a"].state == :needs_review
      assert states["obj-a"].first_mastered_at == t1
      assert states["obj-a"].last_attempt_at == t2
    end

    test "objectives 之外的 attempt 不进投影" do
      states = Mastery.states([attempt("obj-ghost", @t0)], objectives())

      assert map_size(states) == 3
      refute Map.has_key?(states, "obj-ghost")
    end
  end

  describe "states/2 latest-attempt-driven 恢复语义(S9,R45)" do
    test "needs_review 可恢复:失败后再次 qualifying → mastered,ever_mastered 全程 true" do
      t1 = @t0
      t2 = DateTime.add(@t0, 3600, :second)
      t3 = DateTime.add(@t0, 7200, :second)

      # 中间态:失败后 = needs_review
      mid = Mastery.states([qualifying_a(t1), attempt("obj-a", t2, passed: false)], objectives())
      assert mid["obj-a"].state == :needs_review
      assert mid["obj-a"].ever_mastered == true

      # 再次 qualifying → 恢复 mastered(first_mastered_at 锚定首条 qualifying 不变)
      attempts = [qualifying_a(t1), attempt("obj-a", t2, passed: false), qualifying_a(t3)]
      entry = Mastery.states(attempts, objectives())["obj-a"]

      assert entry.state == :mastered
      assert entry.ever_mastered == true
      assert entry.first_mastered_at == t1
      assert entry.last_attempt_at == t3
      assert entry.attempt_count == 3
    end

    test "失败后再次失败 → 仍 needs_review(最新驱动,不因更早的 qualifying 误判 mastered)" do
      t1 = @t0
      t2 = DateTime.add(@t0, 3600, :second)
      t3 = DateTime.add(@t0, 7200, :second)

      attempts = [
        qualifying_a(t1),
        attempt("obj-a", t2, passed: false),
        attempt("obj-a", t3, passed: false)
      ]

      entry = Mastery.states(attempts, objectives())["obj-a"]

      assert entry.state == :needs_review
      assert entry.ever_mastered == true
      assert entry.first_mastered_at == t1
    end

    test "先失败后 qualifying → mastered(developing 的正常进阶,不误判 needs_review)" do
      t1 = @t0
      t2 = DateTime.add(@t0, 3600, :second)

      attempts = [attempt("obj-a", t1, passed: false), qualifying_a(t2)]
      entry = Mastery.states(attempts, objectives())["obj-a"]

      assert entry.state == :mastered
      assert entry.ever_mastered == true
      assert entry.first_mastered_at == t2
    end
  end

  describe "完成判据(R39)" do
    test "ever_mastered?/2:缺条目 / 未掌握 → false;needs_review 仍 true" do
      states =
        Mastery.states(
          [qualifying_a(@t0), attempt("obj-a", DateTime.add(@t0, 60, :second), passed: false)],
          objectives()
        )

      assert Mastery.ever_mastered?(states, "obj-a")
      refute Mastery.ever_mastered?(states, "obj-b")
      refute Mastery.ever_mastered?(states, "obj-ghost")
    end

    test "all_required_ever_mastered?:全必修 ever → true(needs_review 不倒退,选修不计)" do
      t1 = @t0
      t2 = DateTime.add(@t0, 60, :second)

      attempts = [
        qualifying_a(t1),
        # obj-a 后来失败 → needs_review,仍计完成
        attempt("obj-a", t2, passed: false),
        attempt("obj-b", t2)
      ]

      states = Mastery.states(attempts, objectives())
      assert states["obj-a"].state == :needs_review
      # 选修 obj-c 未做不影响完成
      assert Mastery.all_required_ever_mastered?(states, objectives())
    end

    test "all_required_ever_mastered?:部分必修 → false;必修空集 → false(防误判)" do
      states = Mastery.states([qualifying_a(@t0)], objectives())
      refute Mastery.all_required_ever_mastered?(states, objectives())

      elective_only = [Enum.at(objectives(), 2)]
      elective_states = Mastery.states([attempt("obj-c", @t0)], elective_only)
      assert elective_states["obj-c"].state == :mastered
      refute Mastery.all_required_ever_mastered?(elective_states, elective_only)

      refute Mastery.all_required_ever_mastered?(%{}, [])
    end
  end
end
