defmodule Cgc2046.Events.EventLifecycleWorkerTest do
  @moduledoc """
  E-9 #124 到点扫描测试：registration_deadline 过点的 open Event/Course → close。

  deadline 回填走裸 SQL（布置而非被测对象，同 EventsFixtures.force_open 惯例）。
  """

  use Cgc2046Web.ConnCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Courses.Course
  alias Cgc2046.Events.Event
  alias Cgc2046.Events.EventLifecycleWorker

  defp backdate_deadline(table, id, interval) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE #{table} SET registration_deadline = NOW() - interval '#{interval}' WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )
  end

  defp status_of(resource, id), do: Ash.get!(resource, id, authorize?: false).status

  test "deadline 过点的 open Event/Course 被 close，未过点/无截止不动" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)

    overdue_event = EventFixtures.create_event(workspace, admin)
    overdue_course = EventFixtures.create_course(workspace, admin)
    future_event = EventFixtures.create_event(workspace, admin)
    no_deadline_event = EventFixtures.create_event(workspace, admin)

    backdate_deadline("events", overdue_event.id, "1 hour")
    backdate_deadline("courses", overdue_course.id, "1 hour")
    backdate_deadline("events", future_event.id, "-1 hour")

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE events SET registration_deadline = NULL WHERE id = $1",
        [Ecto.UUID.dump!(no_deadline_event.id)]
      )

    assert :ok = perform_job(EventLifecycleWorker, %{})

    assert status_of(Event, overdue_event.id) == :closed
    assert status_of(Course, overdue_course.id) == :closed
    assert status_of(Event, future_event.id) == :open
    assert status_of(Event, no_deadline_event.id) == :open
  end

  test "无成班判定且无报名截止的 open 活动在 ends_at 过点关闭（押金场进 no-show 结算的前提）" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)

    # 主用例：min_participants=nil ∧ registration_deadline=nil ∧ ends_at 已过 → closed
    deposit_shaped =
      EventFixtures.create_event(workspace, admin, %{
        registration_deadline: nil,
        ends_at: DateTime.add(DateTime.utc_now(), -1, :hour)
      })

    # 对照：有 deadline 的仍在 deadline 关闭（ends_at 未过点也关）
    deadline_event =
      EventFixtures.create_event(workspace, admin, %{
        ends_at: DateTime.add(DateTime.utc_now(), 10, :day)
      })

    backdate_deadline("events", deadline_event.id, "1 hour")

    # 对照：min_participants 非空 + 无截止 + ends_at 已过 → 不受新分支影响
    qualified_shaped =
      EventFixtures.create_event(workspace, admin, %{
        min_participants: 2,
        registration_deadline: nil,
        ends_at: DateTime.add(DateTime.utc_now(), -1, :hour)
      })

    # 对照：无截止但 ends_at 未过点 → 不动
    future_ends =
      EventFixtures.create_event(workspace, admin, %{
        registration_deadline: nil,
        ends_at: DateTime.add(DateTime.utc_now(), 10, :day)
      })

    assert :ok = perform_job(EventLifecycleWorker, %{})

    assert status_of(Event, deposit_shaped.id) == :closed
    assert status_of(Event, deadline_event.id) == :closed
    assert status_of(Event, qualified_shaped.id) == :open
    assert status_of(Event, future_ends.id) == :open
  end

  test "重复拍幂等：已 closed 的实体不被再拍（状态守卫 + 唯一任务）" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin)
    backdate_deadline("events", event.id, "1 hour")

    assert :ok = perform_job(EventLifecycleWorker, %{})
    assert :ok = perform_job(EventLifecycleWorker, %{})

    assert status_of(Event, event.id) == :closed
  end

  test "draft 实体不被扫中（仅 open 扫描）" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)

    draft =
      Event
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Draft",
          enrollment_policy: :open,
          registration_deadline: DateTime.add(DateTime.utc_now(), -1, :hour)
        },
        tenant: workspace.id
      )
      |> Ash.create!(tenant: workspace.id, actor: admin)

    assert :ok = perform_job(EventLifecycleWorker, %{})
    assert status_of(Event, draft.id) == :draft
  end
end
