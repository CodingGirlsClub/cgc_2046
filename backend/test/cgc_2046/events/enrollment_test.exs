defmodule Cgc2046.Events.EnrollmentTest do
  use Cgc2046.DataCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.{Enrollment, InviteBatch}
  alias Cgc2046.EventsFixtures, as: EventFixtures

  describe "create_enrollment" do
    test "open 活动立即 confirmed，并原子占用一个名额" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{capacity: 1})
      learner = Fixtures.register_user("enrollment-open")

      assert {:ok, enrollment} = create_enrollment(event, learner)
      assert enrollment.status == :confirmed
      assert enrollment.capacity_seq == 1

      reloaded = Ash.get!(event.__struct__, event.id, authorize?: false)
      assert reloaded.confirmed_count == 1

      second = Fixtures.register_user("enrollment-full")
      assert {:error, error} = create_enrollment(event, second)
      assert Exception.message(error) =~ "capacity"
      assert enrollment_count(event.id) == 1
    end

    test "request 活动先 pending，Owner/Admin 确认时才占名额；普通成员无权审批" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{capacity: 1, enrollment_policy: :request})

      learner = Fixtures.register_user("enrollment-request")
      member = Fixtures.register_user("enrollment-member")
      Fixtures.add_member(workspace, member)

      assert {:ok, pending} = create_enrollment(event, learner)
      assert pending.status == :pending
      refute is_nil(pending.approval_deadline)
      assert Ash.get!(event.__struct__, event.id, authorize?: false).confirmed_count == 0

      assert {:error, _} = confirm(pending, member)
      assert {:ok, confirmed} = confirm(pending, admin)
      assert confirmed.status == :confirmed
      assert confirmed.approved_by == admin.id
      refute is_nil(confirmed.approved_at)
      assert Ash.get!(event.__struct__, event.id, authorize?: false).confirmed_count == 1
    end

    test "outsider 非本 workspace 成员审批 pending 报名被拒，状态不变（Phase 5 越权演练）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{enrollment_policy: :request})
      learner = Fixtures.register_user("enrollment-outsider-applicant")
      outsider = Fixtures.register_user("enrollment-outsider")
      {:ok, pending} = create_enrollment(event, learner)

      assert {:error, _} = confirm(pending, outsider)

      assert {:error, _} =
               pending
               |> Ash.Changeset.for_update(:reject_enrollment, %{rejection_reason: "越权"})
               |> Ash.update(tenant: workspace.id, actor: outsider)

      reloaded = Ash.get!(Enrollment, pending.id, authorize?: false)
      assert reloaded.status == :pending
      assert is_nil(reloaded.approved_by)
    end

    test "reject 记录审批人与原因，终态不能再次审批" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{enrollment_policy: :request})
      learner = Fixtures.register_user("enrollment-reject")
      {:ok, pending} = create_enrollment(event, learner)

      assert {:ok, rejected} =
               pending
               |> Ash.Changeset.for_update(:reject_enrollment, %{rejection_reason: "材料不完整"})
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert rejected.status == :rejected
      assert rejected.approved_by == admin.id
      assert rejected.rejection_reason == "材料不完整"
      assert {:error, _} = confirm(rejected, admin)
    end

    test "event/course 二选一且各自防重复报名" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      course = EventFixtures.create_course(workspace, admin)
      learner = Fixtures.register_user("enrollment-unique")

      assert {:ok, _} = create_enrollment(event, learner)
      assert {:error, _} = create_enrollment(event, learner)

      assert {:ok, _} = create_enrollment(course, learner)

      assert {:error, _} =
               Enrollment
               |> Ash.Changeset.for_create(:create_enrollment, %{
                 event_id: event.id,
                 course_id: course.id,
                 user_id: learner.id
               })
               |> Ash.create(tenant: workspace.id, actor: learner)
    end

    test "invite_only 成功报名原子消耗批次配额，quota=1 后拒绝第二人" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{enrollment_policy: :invite_only})

      batch =
        InviteBatch
        |> Ash.Changeset.for_create(:create, %{
          event_id: event.id,
          invite_code: "CAMPUS_A",
          quota: 1
        })
        |> Ash.create!(tenant: workspace.id, actor: admin)

      first = Fixtures.register_user("invite-first")
      second = Fixtures.register_user("invite-second")

      assert {:ok, enrollment} = create_enrollment(event, first, %{invite_code: "CAMPUS_A"})
      assert enrollment.invite_batch_id == batch.id
      assert Ash.get!(InviteBatch, batch.id, authorize?: false).remaining_quota == 0

      assert {:error, error} = create_enrollment(event, second, %{invite_code: "CAMPUS_A"})
      assert Exception.message(error) =~ "quota"
      assert Ash.get!(InviteBatch, batch.id, authorize?: false).remaining_quota == 0
    end

    test "旧 pending 记录在并发确认后取消，仍释放已占用名额" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{capacity: 1, enrollment_policy: :request})

      learner = Fixtures.register_user("enrollment-stale-cancel")

      assert {:ok, stale_pending} = create_enrollment(event, learner)
      assert {:ok, _confirmed} = confirm(stale_pending, admin)

      assert {:ok, cancelled} =
               stale_pending
               |> Ash.Changeset.for_update(:cancel, %{})
               |> Ash.update(tenant: workspace.id, actor: learner)

      assert cancelled.status == :cancelled
      assert Ash.get!(event.__struct__, event.id, authorize?: false).confirmed_count == 0
    end

    test "显式传错 tenant 仍报 target_tenant_mismatch（#104 验收：派生不放开越权）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      other_workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      learner = Fixtures.register_user("enrollment-wrong-tenant")

      assert {:error, error} =
               Enrollment
               |> Ash.Changeset.for_create(:create_enrollment, %{
                 event_id: event.id,
                 user_id: learner.id
               })
               |> Ash.create(tenant: other_workspace.id, actor: learner)

      assert Exception.message(error) =~ "target does not belong to tenant"
    end
  end

  describe "信号发布（enrollment.submitted / completed）" do
    test "request 策略 create 发 submitted（status=pending），不发 completed（AE1）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{enrollment_policy: :request})
      learner = Fixtures.register_user("enrollment-signal-request")

      subscribe_signals(["enrollment.submitted", "enrollment.completed"])

      assert {:ok, pending} = create_enrollment(event, learner)
      assert pending.status == :pending

      assert_receive {:signal, "enrollment.submitted", submitted}, 1_000
      assert submitted["status"] == "pending"
      assert submitted["enrollment_id"] == pending.id
      refute_receive {:signal, "enrollment.completed", _}, 500
    end

    test "open 策略 create 自动确认：submitted 与 completed 各一条（AE5）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{capacity: 10})
      learner = Fixtures.register_user("enrollment-signal-open")

      subscribe_signals(["enrollment.submitted", "enrollment.completed"])

      assert {:ok, enrollment} = create_enrollment(event, learner)
      assert enrollment.status == :confirmed

      assert_receive {:signal, "enrollment.submitted", submitted}, 1_000
      assert submitted["status"] == "confirmed"
      assert submitted["enrollment_id"] == enrollment.id

      assert_receive {:signal, "enrollment.completed", completed}, 1_000
      assert completed["status"] == "confirmed"
      assert completed["idempotency_key"] == "enrollment.completed:" <> enrollment.id
    end

    test "invite_only 有效邀请码 create 自动确认并发 completed" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{enrollment_policy: :invite_only})

      _batch =
        InviteBatch
        |> Ash.Changeset.for_create(:create, %{
          event_id: event.id,
          invite_code: "CAMPUS_B",
          quota: 1
        })
        |> Ash.create!(tenant: workspace.id, actor: admin)

      learner = Fixtures.register_user("enrollment-signal-invite")

      subscribe_signals(["enrollment.completed"])

      assert {:ok, enrollment} = create_enrollment(event, learner, %{invite_code: "CAMPUS_B"})
      assert enrollment.status == :confirmed

      assert_receive {:signal, "enrollment.completed", completed}, 1_000
      assert completed["idempotency_key"] == "enrollment.completed:" <> enrollment.id
      assert completed["enrollment_id"] == enrollment.id
    end

    test "重复 confirm 只发一次 completed（AE4）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{enrollment_policy: :request})
      learner = Fixtures.register_user("enrollment-signal-reconfirm")
      {:ok, pending} = create_enrollment(event, learner)

      subscribe_signals(["enrollment.completed"])

      assert {:ok, _confirmed} = confirm(pending, admin)
      assert_receive {:signal, "enrollment.completed", _}, 1_000

      assert {:error, _} = confirm(pending, admin)
      refute_receive {:signal, "enrollment.completed", _}, 500
    end

    test "reject 不发出 completed" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{enrollment_policy: :request})
      learner = Fixtures.register_user("enrollment-signal-reject")
      {:ok, pending} = create_enrollment(event, learner)

      subscribe_signals(["enrollment.completed"])

      assert {:ok, _rejected} =
               pending
               |> Ash.Changeset.for_update(:reject_enrollment, %{rejection_reason: "材料不完整"})
               |> Ash.update(tenant: workspace.id, actor: admin)

      refute_receive {:signal, "enrollment.completed", _}, 500
    end

    test "发布失败（bus 报错）→ action 仍成功且错误被记录（KTD4）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{capacity: 10})
      learner = Fixtures.register_user("enrollment-signal-publish-fail")

      # 经 supervisor 终止 bus（permanent 子进程不会被自动重启，发布确定性失败；
      # 与 GenServer.stop + 自动重启相比无竞态）。测试后恢复。
      bus_id = Cgc2046.Workflows.JidoAdapter.bus_name()
      assert :ok = Supervisor.terminate_child(Cgc2046.Supervisor, bus_id)

      try do
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:ok, enrollment} = create_enrollment(event, learner)
            assert enrollment.status == :confirmed
          end)

        assert log =~ "enrollment.submitted"
      after
        # 恢复 bus（后续测试依赖信号总线）
        assert {:ok, _pid} = Supervisor.restart_child(Cgc2046.Supervisor, bus_id)
      end
    end
  end

  describe "ApprovalExpiryWorker" do
    test "过期 pending Enrollment 转 expired 并落 expired_at" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{enrollment_policy: :request})
      learner = Fixtures.register_user("enrollment-expire")
      {:ok, pending} = create_enrollment(event, learner)

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE enrollments SET approval_deadline = NOW() - INTERVAL '1 minute' WHERE id = $1",
          [Ecto.UUID.dump!(pending.id)]
        )

      assert :ok = Cgc2046.Workers.ApprovalExpiryWorker.perform(%Oban.Job{})
      expired = Ash.get!(Enrollment, pending.id, authorize?: false)
      assert expired.status == :expired
      refute is_nil(expired.expired_at)

      assert {:ok, resubmitted} = create_enrollment(event, learner)
      assert resubmitted.status == :pending
      assert resubmitted.id != expired.id
    end
  end

  defp subscribe_signals(patterns) do
    parent = self()

    Enum.each(patterns, fn pattern ->
      assert {:ok, _sub_id} =
               Cgc2046.Workflows.JidoAdapter.subscribe(
                 pattern,
                 fn signal -> send(parent, {:signal, signal.type, signal.data}) end,
                 nil
               )
    end)
  end

  defp create_enrollment(target, user, attrs \\ %{}) do
    target_key = if target.__struct__ == Cgc2046.Events.Event, do: :event_id, else: :course_id

    attrs = Map.merge(%{target_key => target.id, user_id: user.id}, attrs)

    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, attrs)
    |> Ash.create(tenant: target.workspace_id, actor: user)
  end

  defp confirm(enrollment, actor) do
    enrollment
    |> Ash.Changeset.for_update(:confirm_enrollment, %{})
    |> Ash.update(tenant: enrollment.workspace_id, actor: actor)
  end

  defp enrollment_count(event_id) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        "SELECT count(*) FROM enrollments WHERE event_id = $1",
        [Ecto.UUID.dump!(event_id)]
      )

    count
  end
end
