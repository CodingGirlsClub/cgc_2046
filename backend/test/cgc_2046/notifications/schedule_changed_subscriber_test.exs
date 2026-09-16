defmodule Cgc2046.Notifications.ScheduleChangedSubscriberTest do
  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  import Ecto.Query

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures
  alias Cgc2046.Notifications.{NotificationDelivery, ScheduleChangedSubscriber}
  alias Cgc2046.Notifications.Workers.ScheduleChangedFanoutWorker

  @time_window 300
  @default_window 900
  @window_tolerance_seconds 60

  defp setup_event_with_enrollment do
    admin = Fixtures.platform_admin("schedule-subscriber")
    workspace = Fixtures.create_workspace(admin)
    learner = Fixtures.register_user("schedule-learner")
    event = EventsFixtures.create_event(workspace, admin)

    {:ok, _enrollment} =
      Cgc2046.Admission.Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{event_id: event.id, user_id: learner.id})
      |> Ash.create(tenant: workspace.id, actor: learner)

    %{event: event, workspace: workspace, learner: learner}
  end

  defp signal(event_id, changed) when is_list(changed),
    do: %{"event_id" => event_id, "changed" => changed}

  # 只数 scheduled 态（手插的 executing 旧 job / 已执行 job 不计）
  defp scheduled_jobs(event_id) do
    from(j in Oban.Job,
      where: j.worker == "Cgc2046.Notifications.Workers.ScheduleChangedFanoutWorker",
      where: j.state == "scheduled",
      where: fragment("?->>'event_id' = ?", j.args, ^event_id)
    )
    |> Cgc2046.Repo.all()
  end

  defp within_window?(%DateTime{} = scheduled_at, seconds) do
    expected = DateTime.add(DateTime.utc_now(), seconds, :second)
    abs(DateTime.diff(scheduled_at, expected)) <= @window_tolerance_seconds
  end

  describe "handle/2 debounce 入队（#565）" do
    test "时间变更信号 → 一条 5 分钟档 scheduled fanout job" do
      %{event: event} = setup_event_with_enrollment()

      assert :ok =
               ScheduleChangedSubscriber.handle(
                 "event.schedule_changed",
                 signal(event.id, ["starts_at"])
               )

      assert [job] = scheduled_jobs(event.id)
      assert job.args["event_id"] == event.id
      assert within_window?(job.scheduled_at, @time_window)
    end

    test "纯场地变更信号 → 15 分钟档" do
      %{event: event} = setup_event_with_enrollment()

      assert :ok =
               ScheduleChangedSubscriber.handle(
                 "event.schedule_changed",
                 signal(event.id, ["venue"])
               )

      assert [job] = scheduled_jobs(event.id)
      assert within_window?(job.scheduled_at, @default_window)
    end

    test "旧格式信号（无 changed）→ 保守 15 分钟档" do
      %{event: event} = setup_event_with_enrollment()

      assert :ok =
               ScheduleChangedSubscriber.handle("event.schedule_changed", %{
                 "event_id" => event.id
               })

      assert [job] = scheduled_jobs(event.id)
      assert within_window?(job.scheduled_at, @default_window)
    end

    test "连续 3 次编辑（3 条信号）→ 同 event 只有一条 job（unique+replace 合并为一轮）" do
      %{event: event} = setup_event_with_enrollment()

      for changed <- [["starts_at"], ["venue"], ["starts_at", "venue"]] do
        assert :ok =
                 ScheduleChangedSubscriber.handle(
                   "event.schedule_changed",
                   signal(event.id, changed)
                 )
      end

      assert [job] = scheduled_jobs(event.id)
      # 最后一次信号（starts_at+venue 同变）→ 时间敏感档 5 分钟
      assert within_window?(job.scheduled_at, @time_window)
    end

    test "旧 job 已 executing 时新信号仍建立新 job（最终态必达优先于去重）" do
      %{event: event} = setup_event_with_enrollment()

      # 手插一条 executing 态旧 job（绕过 Oban.insert 的 unique 检查，模拟旧
      # job 正在执行的瞬间又有编辑）——钉住 unique states 不含 available/
      # executing 的配置回归（改回 :incomplete 会挡掉新插入 → 必达破坏）
      Cgc2046.Repo.insert!(%Oban.Job{
        args: %{"event_id" => event.id},
        worker: "Cgc2046.Notifications.Workers.ScheduleChangedFanoutWorker",
        queue: "notifications",
        state: "executing"
      })

      assert :ok =
               ScheduleChangedSubscriber.handle(
                 "event.schedule_changed",
                 signal(event.id, ["venue"])
               )

      assert [job] = scheduled_jobs(event.id)
      assert within_window?(job.scheduled_at, @default_window)
    end
  end

  describe "fanout（#565 latest-wins）" do
    test "执行时回查 event 真状态：信号之后场地再改，通知内容=最新值" do
      %{event: event, workspace: workspace} = setup_event_with_enrollment()

      assert :ok =
               ScheduleChangedSubscriber.handle(
                 "event.schedule_changed",
                 signal(event.id, ["venue"])
               )

      # 窗口内组织者又改了场地（fanout 尚未执行）；venue 是结构化 :map
      new_venue = %{"country" => "中国", "province" => "北京市", "city" => "北京", "district" => "朝阳区"}

      event
      |> Ash.Changeset.for_update(:update, %{venue: new_venue}, authorize?: false)
      |> Ash.update!(tenant: workspace.id)

      assert :ok = perform_job(ScheduleChangedFanoutWorker, %{"event_id" => event.id})

      assert [%{template_key: "event_schedule_changed", data: data}] =
               Ash.read!(NotificationDelivery, authorize?: false)

      assert data["venue"]["district"] == "朝阳区"
      assert data["event_id"] == event.id
      assert data["title"] == event.title
    end

    test "执行后活跃报名逐人落 delivery rows（一轮一条）" do
      %{event: event} = setup_event_with_enrollment()

      assert :ok = perform_job(ScheduleChangedFanoutWorker, %{"event_id" => event.id})

      assert [%{template_key: "event_schedule_changed", status: :pending, user_id: user_id}] =
               Ash.read!(NotificationDelivery, authorize?: false)

      assert is_binary(user_id)
    end

    test "event 已删 → 静默成功，不落 delivery" do
      setup_event_with_enrollment()

      assert :ok = perform_job(ScheduleChangedFanoutWorker, %{"event_id" => Ecto.UUID.generate()})

      assert [] = Ash.read!(NotificationDelivery, authorize?: false)
    end
  end
end
