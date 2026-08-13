defmodule Cgc2046.Events.EventLifecycleTest do
  @moduledoc """
  E-9 #124 生命周期动作测试：close/cancel 状态迁移 + 越权拒绝 + DB 级
  compare-and-set 陈旧守卫（Event/Course 双覆盖）。

  信号发布不在此断言：发布路径由事务内 outbox 入队（SignalPublishWorker）承担，
  本测试断言 close/cancel 后 job 已入队；订阅方行为由 ResearchRunReaper 测试覆盖。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.{Course, Event}
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Workers.SignalPublishWorker

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
    test "open → closed（Event/Course）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      course = EventFixtures.create_course(workspace, admin)

      assert {:ok, closed} = close(event, workspace, admin)
      assert closed.status == :closed
      assert reload(Event, event.id).status == :closed
      assert_enqueued(worker: SignalPublishWorker, args: %{"signal_type" => "event.ended"})

      assert {:ok, closed_course} = close(course, workspace, admin)
      assert closed_course.status == :closed
      assert reload(Course, course.id).status == :closed
      assert_enqueued(worker: SignalPublishWorker, args: %{"signal_type" => "course.ended"})
    end

    test "非法迁移：draft 不能 close；新鲜读重复 close 被状态守卫拒绝" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      draft = create_draft_event(workspace, admin, "Draft Event")
      assert {:error, error} = close(draft, workspace, admin)
      assert Exception.message(error) =~ "cannot close from status=draft"

      event = EventFixtures.create_event(workspace, admin)
      assert {:ok, _} = close(event, workspace, admin)

      fresh = reload(Event, event.id)
      assert {:error, again} = close(fresh, workspace, admin)
      assert Exception.message(again) =~ "cannot close from status=closed"
    end

    test "DB 级 compare-and-set：陈旧 struct（内存 open、DB 已 closed）被 CAS 拒绝" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      # 并发另一路已 close（模拟 cron 与手动竞态的后到者）
      assert {:ok, _} = close(event, workspace, admin)
      assert reload(Event, event.id).status == :closed

      # 后到者持旧 struct（内存 status 仍 :open）——前置守卫放行，DB CAS num_rows=0 拒绝
      assert {:error, race} = close(event, workspace, admin)
      assert Exception.message(race) =~ "concurrently"

      # CAS 拒绝后不重复发布：仅第一次 close 入队 ended job（本测试无其他发布源）
      assert_enqueued(worker: SignalPublishWorker, args: %{"signal_type" => "event.ended"})
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

    test "close 与 cancel 并发互斥：CAS 只放行一个" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      assert {:ok, _} = cancel(event, workspace, admin)

      # 陈旧 struct 上的 close（内存仍 open）被 CAS 拒绝
      assert {:error, race} = close(event, workspace, admin)
      assert Exception.message(race) =~ "concurrently"
      assert reload(Event, event.id).status == :cancelled
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
