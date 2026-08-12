defmodule Cgc2046.Events.EventLifecycleTest do
  @moduledoc """
  E-9 #124 生命周期动作测试：close/cancel 状态迁移 + 越权拒绝（Event/Course 双覆盖）。

  信号发布不在此断言：信号总线异步投递在 POC 已验证，测试不覆盖异步路径
  （同 ResearchInstantiator 纪律）；发布契约由 :close/:cancel 的
  after_transaction 接线承担，订阅方行为由 ResearchRunReaper 测试覆盖。
  """

  use Cgc2046.DataCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.{Course, Event}
  alias Cgc2046.EventsFixtures, as: EventFixtures

  defp reload(resource, id), do: Ash.get!(resource, id, authorize?: false)

  defp create_draft_event(workspace, admin, title) do
    Event
    |> Ash.Changeset.for_create(
      :create,
      %{title: title, enrollment_policy: :open},
      tenant: workspace.id
    )
    |> Ash.create!(tenant: workspace.id, actor: admin)
  end

  describe "close" do
    test "open → closed（Event）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      assert {:ok, closed} = close(event, workspace, admin)
      assert closed.status == :closed
      assert reload(Event, event.id).status == :closed
    end

    test "open → closed（Course）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin)

      assert {:ok, closed} = close(course, workspace, admin)
      assert closed.status == :closed
      assert reload(Course, course.id).status == :closed
    end

    test "非法迁移：draft 不能 close，新鲜读下终态不能重复 close" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      draft = create_draft_event(workspace, admin, "Draft Event")
      assert {:error, error} = close(draft, workspace, admin)
      assert Exception.message(error) =~ "cannot close from status=draft"

      event = EventFixtures.create_event(workspace, admin)
      assert {:ok, _} = close(event, workspace, admin)

      # 第二次 close 走新鲜读（现实路径：GraphQL/worker 每次重读）。
      fresh = reload(Event, event.id)
      assert {:error, again} = close(fresh, workspace, admin)
      assert Exception.message(again) =~ "cannot close from status=closed"
    end
  end

  describe "cancel" do
    test "open → cancelled（Event/Course），draft 不能 cancel" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      course = EventFixtures.create_course(workspace, admin)

      assert {:ok, cancelled} = cancel(event, workspace, admin)
      assert cancelled.status == :cancelled
      assert reload(Event, event.id).status == :cancelled

      assert {:ok, cancelled_course} = cancel(course, workspace, admin)
      assert cancelled_course.status == :cancelled

      draft = create_draft_event(workspace, admin, "Draft 2")
      assert {:error, error} = cancel(draft, workspace, admin)
      assert Exception.message(error) =~ "cannot cancel from status=draft"
    end
  end

  describe "authorization" do
    test "普通成员不能 close/cancel（Owner/Admin 或平台管理员专属）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      member = Fixtures.register_user("lifecycle-member")
      Fixtures.add_member(workspace, member)

      assert {:error, _} = close(event, workspace, member)
      assert {:error, _} = cancel(event, workspace, member)
      assert reload(Event, event.id).status == :open
    end
  end

  defp close(entity, workspace, actor) do
    entity
    |> Ash.Changeset.for_update(:close, %{}, tenant: workspace.id, actor: actor)
    |> Ash.update(tenant: workspace.id, actor: actor)
  end

  defp cancel(entity, workspace, actor) do
    entity
    |> Ash.Changeset.for_update(:cancel, %{}, tenant: workspace.id, actor: actor)
    |> Ash.update(tenant: workspace.id, actor: actor)
  end
end
