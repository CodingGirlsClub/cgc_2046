defmodule Cgc2046.Learning.NextActionTest do
  @moduledoc """
  NextAction 纯函数测试(S8,R40/R41;S9 复习到期队列条目形状,R45):完成守卫
  先行;优先级 review → remediation → developing → next_required → elective;
  锁定纪律(unlocked?/missing_prereq_ids)。纯函数,无 DB。
  """
  use ExUnit.Case, async: true

  alias Cgc2046.Learning.NextAction

  @t0 ~U[2026-08-01 10:00:00Z]

  # obj-1 必修无先修;obj-2 必修先修 obj-1;obj-3 选修无先修
  defp objectives do
    [
      %{"id" => "obj-1", "title" => "运行程序", "required" => true, "prereq_ids" => []},
      %{"id" => "obj-2", "title" => "讲懂代码", "required" => true, "prereq_ids" => ["obj-1"]},
      %{"id" => "obj-3", "title" => "变量拓展", "required" => false, "prereq_ids" => []}
    ]
  end

  defp entry(state, opts) do
    %{
      state: state,
      ever_mastered: Keyword.get(opts, :ever_mastered, state in [:mastered, :needs_review]),
      attempt_count: Keyword.get(opts, :attempt_count, 1),
      last_attempt_at: Keyword.get(opts, :last_attempt_at),
      first_mastered_at: nil
    }
  end

  # ReviewSchedule 队列条目形状(S9):复习分支只消费 objective_id / needs_review
  defp review_entry(objective_id, opts \\ []) do
    %{
      objective_id: objective_id,
      due_at: Keyword.get(opts, :due_at, @t0),
      milestone_days: Keyword.get(opts, :milestone_days, 1),
      needs_review: Keyword.get(opts, :needs_review, false)
    }
  end

  describe "完成守卫(R39 先行)" do
    test "全必修 ever_mastered → nil(选修未做也不再推荐;needs_review 不倒退)" do
      states = %{
        "obj-1" => entry(:mastered, last_attempt_at: @t0),
        "obj-2" => entry(:needs_review, last_attempt_at: @t0)
      }

      assert NextAction.next(objectives(), states) == nil
    end
  end

  describe "优先级 ① review" do
    test "复习到期队列队首优先;队列 id 不在内容中则落空继续向下" do
      queue = [review_entry("obj-3")]
      action = NextAction.next(objectives(), %{}, queue)

      assert action.kind == :review
      assert action.objective_id == "obj-3"
      assert action.reason =~ "复习"
      assert action.reason =~ "变量拓展"

      # 队首条目已不在 objectives → 落空,按后续优先级推荐
      assert NextAction.next(objectives(), %{}, [review_entry("ghost")]).kind == :next_required
    end

    test "needs_review 条目 reason 明示「待复习」(S9/R45)" do
      action = NextAction.next(objectives(), %{}, [review_entry("obj-1", needs_review: true)])

      assert action.kind == :review
      assert action.objective_id == "obj-1"
      assert action.reason =~ "待复习"
      assert action.reason =~ "运行程序"
    end
  end

  describe "优先级 ④ next_required" do
    test "全 unassessed → 内容序首个必修且已解锁(obj-2 锁定被跳过)" do
      action = NextAction.next(objectives(), %{})

      assert action.kind == :next_required
      assert action.objective_id == "obj-1"
      assert action.reason =~ "运行程序"
    end

    test "obj-1 掌握后 obj-2 解锁 → 推荐 obj-2;选修永不进 next_required" do
      states = %{"obj-1" => entry(:mastered, last_attempt_at: @t0)}

      action = NextAction.next(objectives(), states)
      assert action.kind == :next_required
      assert action.objective_id == "obj-2"
    end
  end

  describe "优先级 ② remediation / ③ developing" do
    test "唯一 developing → 继续该 objective" do
      states = %{"obj-1" => entry(:developing, last_attempt_at: @t0)}

      action = NextAction.next(objectives(), states)
      assert action.kind == :developing
      assert action.objective_id == "obj-1"
      assert action.reason =~ "运行程序"
    end

    test "多个 developing 取 last_attempt_at 最新者(不分必修选修)" do
      t1 = @t0
      t2 = DateTime.add(@t0, 3600, :second)

      states = %{
        "obj-1" => entry(:developing, last_attempt_at: t1),
        "obj-3" => entry(:developing, last_attempt_at: t2)
      }

      action = NextAction.next(objectives(), states)
      assert action.kind == :developing
      assert action.objective_id == "obj-3"
    end

    test "当前 developing 的先修有 needs_review → remediation 回补先修" do
      t1 = @t0
      t2 = DateTime.add(@t0, 3600, :second)

      states = %{
        "obj-1" => entry(:needs_review, last_attempt_at: t1),
        "obj-2" => entry(:developing, last_attempt_at: t2)
      }

      action = NextAction.next(objectives(), states)
      assert action.kind == :remediation
      assert action.objective_id == "obj-1"
      assert action.reason =~ "回补"
      assert action.reason =~ "运行程序"
    end

    test "多个 needs_review 先修按 prereq_ids 序取首个(而非按时间)" do
      objectives = [
        %{"id" => "obj-a", "title" => "A", "required" => true, "prereq_ids" => []},
        %{"id" => "obj-b", "title" => "B", "required" => true, "prereq_ids" => []},
        %{"id" => "obj-x", "title" => "X", "required" => true, "prereq_ids" => ["obj-a", "obj-b"]}
      ]

      states = %{
        "obj-a" => entry(:needs_review, last_attempt_at: @t0),
        "obj-b" => entry(:needs_review, last_attempt_at: DateTime.add(@t0, 60, :second)),
        "obj-x" => entry(:developing, last_attempt_at: DateTime.add(@t0, 120, :second))
      }

      action = NextAction.next(objectives, states)
      assert action.kind == :remediation
      assert action.objective_id == "obj-a"
    end
  end

  describe "优先级 ⑤ elective" do
    test "剩余必修全锁定(先修未掌握)时推荐已解锁选修" do
      objectives = [
        %{"id" => "obj-e", "title" => "选修拓展", "required" => false, "prereq_ids" => []},
        %{"id" => "obj-r", "title" => "必修进阶", "required" => true, "prereq_ids" => ["obj-e"]}
      ]

      # obj-r unassessed 但被 obj-e 锁定 → next_required 落空 → elective obj-e
      action = NextAction.next(objectives, %{})
      assert action.kind == :elective
      assert action.objective_id == "obj-e"
      assert action.reason =~ "选修拓展"

      # 选修已 ever_mastered → 不推荐选修;obj-r 解锁 → next_required
      states = %{"obj-e" => entry(:mastered, last_attempt_at: @t0)}
      assert NextAction.next(objectives, states).kind == :next_required
    end
  end

  describe "锁定纪律(R41)" do
    test "unlocked?/missing_prereq_ids:先修未 ever_mastered → 锁定并列出缺失" do
      obj2 = Enum.find(objectives(), &(&1["id"] == "obj-2"))

      refute NextAction.unlocked?(obj2, %{})
      assert NextAction.missing_prereq_ids(obj2, %{}) == ["obj-1"]

      # needs_review 仍 ever_mastered → 解锁
      states = %{"obj-1" => entry(:needs_review, last_attempt_at: @t0)}
      assert NextAction.unlocked?(obj2, states)
      assert NextAction.missing_prereq_ids(obj2, states) == []
    end

    test "无先修 / 先修 id 非字符串残留 → 恒解锁" do
      obj1 = Enum.find(objectives(), &(&1["id"] == "obj-1"))
      assert NextAction.unlocked?(obj1, %{})

      weird = %{"id" => "obj-w", "title" => "W", "required" => true, "prereq_ids" => [nil, 1]}
      assert NextAction.unlocked?(weird, %{})
      assert NextAction.missing_prereq_ids(weird, %{}) == []
    end
  end
end
