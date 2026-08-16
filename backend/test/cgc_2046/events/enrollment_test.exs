defmodule Cgc2046.Events.EnrollmentTest do
  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.{Enrollment, InviteBatch}
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Workers.SignalPublishWorker

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

      assert {:ok, pending} = create_enrollment(event, learner)
      assert pending.status == :pending

      # 事务内 outbox：信号经 SignalPublishWorker job 入队（plan 2026-08-14-003 Q6），
      # 幂等键与 workspace_id 由 SignalEmitter 注入
      assert_enqueued(
        worker: SignalPublishWorker,
        args: %{
          "signal_type" => "enrollment.submitted",
          "tenant" => workspace.id,
          "data" => %{
            "status" => "pending",
            "enrollment_id" => pending.id,
            "enrollment_policy" => "request",
            "event_id" => event.id,
            "course_id" => nil,
            "workspace_id" => workspace.id,
            "user_id" => learner.id,
            "idempotency_key" => "enrollment.submitted:" <> pending.id
          }
        }
      )

      refute_enqueued(
        worker: SignalPublishWorker,
        args: %{
          "signal_type" => "enrollment.completed",
          "data" => %{"enrollment_id" => pending.id}
        }
      )
    end

    test "open 策略 create 自动确认：submitted 与 completed 各一条（AE5）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{capacity: 10})
      learner = Fixtures.register_user("enrollment-signal-open")

      assert {:ok, enrollment} = create_enrollment(event, learner)
      assert enrollment.status == :confirmed

      assert_enqueued(
        worker: SignalPublishWorker,
        args: %{
          "signal_type" => "enrollment.submitted",
          "data" => %{"status" => "confirmed", "enrollment_id" => enrollment.id}
        }
      )

      assert_enqueued(
        worker: SignalPublishWorker,
        args: %{
          "signal_type" => "enrollment.completed",
          "data" => %{
            "status" => "confirmed",
            "idempotency_key" => "enrollment.completed:" <> enrollment.id,
            "enrollment_policy" => "open",
            "event_id" => event.id,
            "workspace_id" => workspace.id,
            "user_id" => learner.id
          }
        }
      )

      # 各一条（本报名 submitted + completed 精确计数）
      assert count_enqueued("enrollment.submitted", enrollment.id) == 1
      assert count_enqueued("enrollment.completed", enrollment.id) == 1
    end

    test "course 目标 create：payload 带 course_id、event_id 为 nil、policy 正确" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{enrollment_policy: :request})
      learner = Fixtures.register_user("enrollment-signal-course")

      assert {:ok, pending} = create_enrollment(course, learner)
      assert pending.status == :pending

      assert_enqueued(
        worker: SignalPublishWorker,
        args: %{
          "signal_type" => "enrollment.submitted",
          "data" => %{
            "enrollment_id" => pending.id,
            "course_id" => course.id,
            "event_id" => nil,
            "enrollment_policy" => "request"
          }
        }
      )
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

      assert {:ok, enrollment} = create_enrollment(event, learner, %{invite_code: "CAMPUS_B"})
      assert enrollment.status == :confirmed

      assert_enqueued(
        worker: SignalPublishWorker,
        args: %{
          "signal_type" => "enrollment.completed",
          "data" => %{
            "idempotency_key" => "enrollment.completed:" <> enrollment.id,
            "enrollment_id" => enrollment.id
          }
        }
      )
    end

    test "重复 confirm 只发一次 completed（AE4）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{enrollment_policy: :request})
      learner = Fixtures.register_user("enrollment-signal-reconfirm")
      {:ok, pending} = create_enrollment(event, learner)

      assert {:ok, _confirmed} = confirm(pending, admin)

      assert_enqueued(
        worker: SignalPublishWorker,
        args: %{
          "signal_type" => "enrollment.completed",
          "data" => %{"idempotency_key" => "enrollment.completed:" <> pending.id}
        }
      )

      assert_enqueued(
        worker: SignalPublishWorker,
        args: %{
          "signal_type" => "enrollment.approved",
          "data" => %{"enrollment_id" => pending.id}
        }
      )

      assert {:error, _} = confirm(pending, admin)

      # 失败的 confirm 不到 after_action：completed/approved 各仍只有一条 job
      assert count_enqueued("enrollment.completed", pending.id) == 1
      assert count_enqueued("enrollment.approved", pending.id) == 1
    end

    test "reject 不发出 completed" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{enrollment_policy: :request})
      learner = Fixtures.register_user("enrollment-signal-reject")
      {:ok, pending} = create_enrollment(event, learner)

      assert {:ok, _rejected} =
               pending
               |> Ash.Changeset.for_update(:reject_enrollment, %{rejection_reason: "材料不完整"})
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert_enqueued(
        worker: SignalPublishWorker,
        args: %{
          "signal_type" => "enrollment.rejected",
          "data" => %{"enrollment_id" => pending.id}
        }
      )

      refute_enqueued(
        worker: SignalPublishWorker,
        args: %{
          "signal_type" => "enrollment.completed",
          "data" => %{"enrollment_id" => pending.id}
        }
      )
    end

    test "bus 宕机不影响 action：job 与报名同事务入队（事务性 outbox 解耦发布失败）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{capacity: 10})
      learner = Fixtures.register_user("enrollment-signal-publish-fail")

      # 经 supervisor terminate_child 终止 bus：子进程从监督树移除，不会自动重启，
      # 投递通道确定性不可用（对比 GenServer.stop：permanent 子进程会被重启，与事务内工作竞态）。
      # 测试后恢复。
      bus_id = Cgc2046.Workflows.JidoAdapter.bus_name()
      assert :ok = Supervisor.terminate_child(Cgc2046.Supervisor, bus_id)

      try do
        # KTD4 语义升级（plan 2026-08-14-003 Q6）：发布失败不再发生在 action 内——
        # job 事务内入队与投递解耦，bus 宕机时报名照常成功，投递由 Oban 重试兜底
        assert {:ok, enrollment} = create_enrollment(event, learner)
        assert enrollment.status == :confirmed

        assert_enqueued(
          worker: SignalPublishWorker,
          args: %{
            "signal_type" => "enrollment.submitted",
            "data" => %{"enrollment_id" => enrollment.id}
          }
        )

        assert_enqueued(
          worker: SignalPublishWorker,
          args: %{
            "signal_type" => "enrollment.completed",
            "data" => %{"idempotency_key" => "enrollment.completed:" <> enrollment.id}
          }
        )
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

  describe "收费报名：payment_pending 插桩（U3，KTD6）" do
    test "open 收费：占位后进 payment_pending（不 confirmed），completed 信号不发（R5/AE5）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{capacity: 1} |> Map.merge(paid_attrs()))

      learner = Fixtures.register_user("enrollment-paid-open")

      assert {:ok, enrollment} = create_enrollment(event, learner)
      assert enrollment.status == :payment_pending
      assert enrollment.capacity_seq == 1
      assert Ash.get!(event.__struct__, event.id, authorize?: false).confirmed_count == 1

      # submitted 发（报名动作发生），completed 不发（未真正确认，KTD6-6）
      assert count_enqueued("enrollment.submitted", enrollment.id) == 1
      assert count_enqueued("enrollment.completed", enrollment.id) == 0
    end

    test "免费 open 隔离对照：现状 confirmed + completed 不变（R4/AE5）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{capacity: 1})
      learner = Fixtures.register_user("enrollment-free-open")

      assert {:ok, enrollment} = create_enrollment(event, learner)
      assert enrollment.status == :confirmed
      assert count_enqueued("enrollment.completed", enrollment.id) == 1
    end

    test "request 收费：报名仍 pending 不占位；审批通过 → 占位 + payment_pending（R10）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(
          workspace,
          admin,
          %{
            capacity: 1,
            enrollment_policy: :request
          }
          |> Map.merge(paid_attrs())
        )

      learner = Fixtures.register_user("enrollment-paid-request")

      assert {:ok, pending} = create_enrollment(event, learner)
      assert pending.status == :pending
      assert Ash.get!(event.__struct__, event.id, authorize?: false).confirmed_count == 0

      assert {:ok, payment_pending} = confirm(pending, admin)
      assert payment_pending.status == :payment_pending
      assert payment_pending.capacity_seq == 1
      assert payment_pending.approved_by == admin.id
      assert Ash.get!(event.__struct__, event.id, authorize?: false).confirmed_count == 1

      # approved 发，completed 不发（支付未完成）
      assert count_enqueued("enrollment.approved", pending.id) == 1
      assert count_enqueued("enrollment.completed", pending.id) == 0
    end

    test "invite_only 收费：校验邀请码 + 扣配额 + 占位 + payment_pending（R10）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(
          workspace,
          admin,
          %{
            enrollment_policy: :invite_only
          }
          |> Map.merge(paid_attrs())
        )

      batch =
        InviteBatch
        |> Ash.Changeset.for_create(:create, %{
          event_id: event.id,
          invite_code: "PAID_INVITE",
          quota: 1
        })
        |> Ash.create!(tenant: workspace.id, actor: admin)

      learner = Fixtures.register_user("enrollment-paid-invite")

      assert {:ok, enrollment} =
               create_enrollment(event, learner, %{invite_code: "PAID_INVITE"})

      assert enrollment.status == :payment_pending
      assert enrollment.capacity_seq == 1
      assert enrollment.invite_batch_id == batch.id
    end

    test "payment_pending 期间不可重复报名（唯一索引扩列）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, paid_attrs())
      learner = Fixtures.register_user("enrollment-paid-dup")

      assert {:ok, _} = create_enrollment(event, learner)
      assert {:error, _} = create_enrollment(event, learner)
    end

    test "cancel payment_pending：名额释放 + 可重新报名（R12）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{capacity: 1} |> Map.merge(paid_attrs()))

      learner = Fixtures.register_user("enrollment-paid-cancel")

      {:ok, enrollment} = create_enrollment(event, learner)

      assert {:ok, cancelled} =
               enrollment
               |> Ash.Changeset.for_update(:cancel, %{})
               |> Ash.update(tenant: workspace.id, actor: learner)

      assert cancelled.status == :cancelled
      assert Ash.get!(event.__struct__, event.id, authorize?: false).confirmed_count == 0

      # 释放后可重新报名（计数回落再占位，重新拿回 1 号位）
      assert {:ok, re} = create_enrollment(event, learner)
      assert re.status == :payment_pending
      assert re.capacity_seq == 1
    end
  end

  describe "waive_payment 免缴（R18，AE3 免缴半）" do
    setup do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, paid_attrs())
      learner = Fixtures.register_user("waive-learner")
      {:ok, enrollment} = create_enrollment(event, learner)

      %{
        admin: admin,
        workspace: workspace,
        event: event,
        learner: learner,
        enrollment: enrollment
      }
    end

    test "Owner/Admin 免缴：payment_pending → confirmed + completed 信号 + 审计行", ctx do
      assert {:ok, waived} = waive(ctx.enrollment, ctx.admin)
      assert waived.status == :confirmed
      assert waived.approved_by == ctx.admin.id
      assert count_enqueued("enrollment.completed", ctx.enrollment.id) == 1

      assert [%{action: :waive_payment, target_type: :enrollment}] =
               Cgc2046.Repo.all(
                 from(log in Cgc2046.Accounts.AdminActionLog,
                   where: log.target_id == ^ctx.enrollment.id
                 )
               )
    end

    test "普通成员无权免缴（403 语义）；PlatformAdmin 可兜底", ctx do
      member = Fixtures.register_user("waive-member")
      Fixtures.add_member(ctx.workspace, member)

      assert {:error, error} = waive(ctx.enrollment, member)
      assert Exception.message(error) =~ "forbidden"

      platform_admin = Fixtures.platform_admin("waive-platform")
      assert {:ok, _} = waive(ctx.enrollment, platform_admin)
    end

    test "状态守卫：pending / confirmed 态免缴被拒", ctx do
      # 已免缴（confirmed）再免缴 → 拒
      {:ok, waived} = waive(ctx.enrollment, ctx.admin)
      assert {:error, _} = waive(waived, ctx.admin)

      # 免费报名（confirmed）不走免缴
      free_event = EventFixtures.create_event(ctx.workspace, ctx.admin)
      learner2 = Fixtures.register_user("waive-free")
      {:ok, free} = create_enrollment(free_event, learner2)
      assert {:error, _} = waive(free, ctx.admin)

      # request pending 未占位 → 无免缴语义
      request_event =
        EventFixtures.create_event(ctx.workspace, ctx.admin, %{enrollment_policy: :request})

      {:ok, request_pending} = create_enrollment(request_event, learner2)
      assert {:error, _} = waive(request_pending, ctx.admin)
    end
  end

  # 按 (signal_type, enrollment_id) 计数：并发类测试（enrollment_concurrency_test
  # 等 unboxed 真实提交）会在套件级残留 SignalPublishWorker 行，断言必须锚定
  # 本测试自己的记录，不受套件内既有 job 影响。
  defp count_enqueued(signal_type, enrollment_id) do
    [worker: SignalPublishWorker]
    |> all_enqueued()
    |> Enum.count(
      &(&1.args["signal_type"] == signal_type &&
          get_in(&1.args, ["data", "enrollment_id"]) == enrollment_id)
    )
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

  defp waive(enrollment, actor) do
    enrollment
    |> Ash.Changeset.for_update(:waive_payment, %{})
    |> Ash.update(tenant: enrollment.workspace_id, actor: actor)
  end

  # 收费活动布置（U2 字段）：两档可售价位
  defp paid_attrs do
    %{
      pricing_enabled: true,
      price_tiers: [
        %{"id" => Ecto.UUID.generate(), "name" => "早鸟", "amount_cents" => 9900},
        %{"id" => Ecto.UUID.generate(), "name" => "标准", "amount_cents" => 19_900}
      ]
    }
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
