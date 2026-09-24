defmodule Cgc2046.Courses.CourseLifecycleTest do
  @moduledoc """
  Course launch/close/cancel 的 action 级竞态测试与状态非法文案断言（#846：
  Event 侧对应覆盖在 Events.EventLifecycleTest，本文件补 Course 缺口）。

  错误文案是硬契约（#846 D2）：web（offering-pages.tsx）正则与 MCP 测试逐字
  依赖这两句——竞态 "<verb> failed: status changed concurrently, retry on
  fresh read"、非法 "cannot <verb> from status=<status>"——断言按整句锚定。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Courses.Course
  alias Cgc2046.EventsFixtures, as: EventFixtures

  defp reload(resource, id), do: Ash.get!(resource, id, authorize?: false)

  defp draft_course(workspace, admin, title) do
    Course
    |> Ash.Changeset.for_create(
      :create,
      %{title: title, registration_deadline: EventFixtures.days_from_now(7)},
      tenant: workspace.id
    )
    |> Ash.create!(tenant: workspace.id, actor: admin)
  end

  defp launch(course, workspace, actor), do: run_action(course, :launch, workspace, actor)
  defp close(course, workspace, actor), do: run_action(course, :close, workspace, actor)
  defp cancel(course, workspace, actor), do: run_action(course, :cancel, workspace, actor)

  defp run_action(course, action, workspace, actor) do
    course
    |> Ash.Changeset.for_update(action, %{}, tenant: workspace.id, actor: actor)
    |> Ash.update(tenant: workspace.id, actor: actor)
  end

  describe "action 级 CAS 竞态（完整文案契约）" do
    test "launch：陈旧 struct（内存 draft、DB 已 open）重发 → 竞态整句拒绝" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      course = draft_course(workspace, admin, "Course Launch CAS")

      assert {:ok, launched} = launch(course, workspace, admin)
      assert launched.status == :open

      # 陈旧 struct（内存仍 draft）再 launch → CAS num_rows=0，整句文案
      assert {:error, race} = launch(course, workspace, admin)

      assert Exception.message(race) =~
               "launch failed: status changed concurrently, retry on fresh read"

      assert reload(Course, course.id).status == :open
    end

    test "close：陈旧 struct（内存 open、DB 已 closed）重发 → 竞态整句拒绝" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin)

      assert {:ok, closed} = close(course, workspace, admin)
      assert closed.status == :closed
      assert reload(Course, course.id).status == :closed

      assert {:error, race} = close(course, workspace, admin)

      assert Exception.message(race) =~
               "close failed: status changed concurrently, retry on fresh read"

      assert reload(Course, course.id).status == :closed
    end

    test "cancel：陈旧 struct（内存 open、DB 已 cancelled）重发 → 竞态整句拒绝" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin)

      assert {:ok, cancelled} = cancel(course, workspace, admin)
      assert cancelled.status == :cancelled
      assert reload(Course, course.id).status == :cancelled

      assert {:error, race} = cancel(course, workspace, admin)

      assert Exception.message(race) =~
               "cancel failed: status changed concurrently, retry on fresh read"

      assert reload(Course, course.id).status == :cancelled
    end
  end

  describe "状态非法（完整文案契约）" do
    test "close：draft 不能 close；新鲜读重复 close 亦拒" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      draft = draft_course(workspace, admin, "Course Close Draft")
      assert {:error, error} = close(draft, workspace, admin)
      assert Exception.message(error) =~ "cannot close from status=draft"

      course = EventFixtures.create_course(workspace, admin)
      assert {:ok, _} = close(course, workspace, admin)

      fresh = reload(Course, course.id)
      assert {:error, again} = close(fresh, workspace, admin)
      assert Exception.message(again) =~ "cannot close from status=closed"
    end

    test "cancel：draft 不能 cancel" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      draft = draft_course(workspace, admin, "Course Cancel Draft")
      assert {:error, error} = cancel(draft, workspace, admin)
      assert Exception.message(error) =~ "cannot cancel from status=draft"
      assert reload(Course, draft.id).status == :draft
    end
  end
end
