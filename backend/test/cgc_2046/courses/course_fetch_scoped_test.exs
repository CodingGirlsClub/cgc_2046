defmodule Cgc2046.Courses.CourseFetchScopedTest do
  @moduledoc """
  `Course.fetch_scoped/3` 租户收紧读取端口契约（2026-09-08 架构评审候选①）：
  取代 18 份工具内私有 fetch_course 拷贝，钉死跨租户不泄存在性与两变体语义分工。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Courses.Course
  alias Cgc2046.EventsFixtures, as: EventFixtures

  describe "默认变体（authorize?: false，授权在工具层）" do
    test "本租户命中返回课程" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      course = EventFixtures.create_course(workspace, owner)

      assert {:ok, %Course{id: id}} = Course.fetch_scoped(workspace.id, course.id)
      assert id == course.id
    end

    test "他租户 course_id 与不存在同一 not found，不泄露存在性" do
      %{workspace: workspace_a} = Fixtures.workspace_with_member()
      %{owner: owner_b, workspace: workspace_b} = Fixtures.workspace_with_member()
      course_b = EventFixtures.create_course(workspace_b, owner_b)

      assert {:error, "course not found: " <> _} =
               Course.fetch_scoped(workspace_a.id, course_b.id)

      assert {:error, "course not found: " <> _} =
               Course.fetch_scoped(workspace_a.id, Ecto.UUID.generate())

      # 对照：本租户可读（同一 id 形状，唯独 tenant 不同）
      assert {:ok, _} = Course.fetch_scoped(workspace_b.id, course_b.id)
    end
  end

  describe "actor 变体（走授权读）" do
    test "owner 读本租户课程" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      course = EventFixtures.create_course(workspace, owner)

      assert {:ok, %Course{id: id}} =
               Course.fetch_scoped(workspace.id, course.id, actor: owner)

      assert id == course.id
    end

    test "他租户 course_id 同样坍缩 not found" do
      %{owner: owner_a, workspace: workspace_a} = Fixtures.workspace_with_member()
      %{owner: owner_b, workspace: workspace_b} = Fixtures.workspace_with_member()
      course_b = EventFixtures.create_course(workspace_b, owner_b)

      assert {:error, "course not found: " <> _} =
               Course.fetch_scoped(workspace_a.id, course_b.id, actor: owner_a)
    end
  end
end
