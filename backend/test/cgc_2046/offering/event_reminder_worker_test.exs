defmodule Cgc2046.Offering.EventReminderWorkerTest do
  @moduledoc """
  #203 方案 B 开始前提醒扫描测试：starts_at 落在 24h 窗口的 open Event/Course
  → confirmed 报名学员入队 event_reminder。

  starts_at / enrollment 状态布置走裸 SQL（布置而非被测对象，
  EventLifecycleWorkerTest.backdate_deadline 同款惯例）。
  """

  use Cgc2046Web.ConnCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Offering.EventReminderWorker
  alias Cgc2046.Repo

  defp set_starts_at(table, id, interval) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Repo,
        "UPDATE #{table} SET starts_at = NOW() + interval '#{interval}' WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )
  end

  defp set_venue(event_id) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Repo,
        """
        UPDATE events SET venue = '{"country":"中国","province":"浙江省","city":"杭州市","district":"西湖区"}'::jsonb
        WHERE id = $1
        """,
        [Ecto.UUID.dump!(event_id)]
      )
  end

  defp insert_enrollment(workspace_id, user_id, event_id, status) do
    {:ok, _} =
      Repo.query(
        """
        INSERT INTO enrollments (id, workspace_id, user_id, event_id, status, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, $2, $3, $4, NOW(), NOW())
        """,
        [Repo.uuid!(workspace_id), Repo.uuid!(user_id), Ecto.UUID.dump!(event_id), status]
      )
  end

  defp insert_wechat_identity(user_id, uid) do
    {:ok, _} =
      Repo.query(
        """
        INSERT INTO user_identities (id, provider, uid, user_id, inserted_at, updated_at)
        VALUES (gen_random_uuid(), 'wechat', $1, $2, NOW(), NOW())
        """,
        [uid, Ecto.UUID.dump!(user_id)]
      )
  end

  defp event_reminder_jobs do
    all_enqueued(worker: Cgc2046.Notifications.NotificationWorker)
    |> Enum.filter(&(&1.args["template_key"] == "event_reminder"))
  end

  test "starts_at 24h 内 open Event 的 confirmed 报名入队（含 venue 拼接）" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    learner = Fixtures.register_user("event-reminder-learner")
    pending_user = Fixtures.register_user("event-reminder-pending")

    insert_wechat_identity(learner.id, "wx-reminder-1")
    insert_wechat_identity(pending_user.id, "wx-reminder-2")

    event = EventFixtures.create_event(workspace, admin)
    set_starts_at("events", event.id, "6 hours")
    set_venue(event.id)
    insert_enrollment(workspace.id, learner.id, event.id, "confirmed")
    insert_enrollment(workspace.id, pending_user.id, event.id, "pending")

    assert :ok = perform_job(EventReminderWorker, %{})

    assert [%{args: args}] = event_reminder_jobs()
    assert args["user_id"] == learner.id
    assert args["identity_uid"] == "wx-reminder-1"
    assert args["data"]["title"] == event.title
    assert args["data"]["starts_at"]
    assert args["data"]["venue"] == "杭州市西湖区"
  end

  test "Course 无 venue 键；窗口外 / 过点 / 无 starts_at 不入队" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    learner = Fixtures.register_user("event-reminder-course-learner")
    insert_wechat_identity(learner.id, "wx-reminder-3")

    in_window_course = EventFixtures.create_course(workspace, admin)
    far_course = EventFixtures.create_course(workspace, admin)
    past_course = EventFixtures.create_course(workspace, admin)
    undated_course = EventFixtures.create_course(workspace, admin)

    set_starts_at("courses", in_window_course.id, "23 hours")
    set_starts_at("courses", far_course.id, "48 hours")
    set_starts_at("courses", past_course.id, "-1 hours")

    for course <- [in_window_course, far_course, past_course, undated_course] do
      insert_course_enrollment(workspace.id, learner.id, course.id)
    end

    assert :ok = perform_job(EventReminderWorker, %{})

    assert [%{args: args}] = event_reminder_jobs()
    assert args["data"]["title"] == in_window_course.title
    refute Map.has_key?(args["data"], "venue")
  end

  test "重扫幂等：args-unique（7 天 states: :all）挡重复入队" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    learner = Fixtures.register_user("event-reminder-idem")
    insert_wechat_identity(learner.id, "wx-reminder-4")

    event = EventFixtures.create_event(workspace, admin)
    set_starts_at("events", event.id, "12 hours")
    insert_enrollment(workspace.id, learner.id, event.id, "confirmed")

    assert :ok = perform_job(EventReminderWorker, %{})
    assert :ok = perform_job(EventReminderWorker, %{})

    assert length(event_reminder_jobs()) == 1
  end

  defp insert_course_enrollment(workspace_id, user_id, course_id) do
    {:ok, _} =
      Repo.query(
        """
        INSERT INTO enrollments (id, workspace_id, user_id, course_id, status, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, $2, $3, 'confirmed', NOW(), NOW())
        """,
        [Repo.uuid!(workspace_id), Repo.uuid!(user_id), Ecto.UUID.dump!(course_id)]
      )
  end
end
