defmodule Cgc2046.Admission.EnrollmentTest do
  @paid_tier_id "33333333-3333-3333-3333-333333333333"

  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.Accounts.UserIdentity
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Admission.{Enrollment, InviteBatch}
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Payments.{Order, Providers.Fake, WebhookEvent}
  alias Cgc2046.Payments.Workers.PaymentRefundWorker
  alias Cgc2046.Payments.Workers.PaymentSettlementWorker
  alias Cgc2046.Workflows.SignalPublishWorker

  import Ecto.Query, only: [from: 2]

  describe "create_enrollment" do
    test "open 活动立即 confirmed，并原子占用一个名额" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{capacity: 1})
      learner = Fixtures.register_user("enrollment-open")

      assert {:ok, enrollment} = create_enrollment(event, learner)
      assert enrollment.status == :confirmed
      assert enrollment.capacity_seq == 1

      # ADR-0009 PR⑤ U6 口径平移：占位计数权威 = 名额账本 occupancy
      assert EventFixtures.ledger_occupancy(event) == 1

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
      assert EventFixtures.ledger_occupancy(event) == 0

      assert {:error, _} = confirm(pending, member)
      assert {:ok, confirmed} = confirm(pending, admin)
      assert confirmed.status == :confirmed
      assert confirmed.approved_by == admin.id
      refute is_nil(confirmed.approved_at)
      assert EventFixtures.ledger_occupancy(event) == 1
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
      assert EventFixtures.ledger_occupancy(event) == 0
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

      assert :ok = Cgc2046.Admission.Workers.ApprovalExpiryWorker.perform(%Oban.Job{})
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

      assert {:ok, enrollment} = create_enrollment(event, learner, %{tier_id: @paid_tier_id})
      assert enrollment.status == :payment_pending
      assert enrollment.capacity_seq == 1
      assert EventFixtures.ledger_occupancy(event) == 1

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

      assert {:ok, pending} = create_enrollment(event, learner, %{tier_id: @paid_tier_id})
      assert pending.status == :pending
      assert EventFixtures.ledger_occupancy(event) == 0

      assert {:ok, payment_pending} = confirm(pending, admin)
      assert payment_pending.status == :payment_pending
      assert payment_pending.capacity_seq == 1
      assert payment_pending.approved_by == admin.id
      assert EventFixtures.ledger_occupancy(event) == 1

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
               create_enrollment(event, learner, %{
                 invite_code: "PAID_INVITE",
                 tier_id: @paid_tier_id
               })

      assert enrollment.status == :payment_pending
      assert enrollment.capacity_seq == 1
      assert enrollment.invite_batch_id == batch.id
    end

    test "payment_pending 期间不可重复报名（唯一索引扩列）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, paid_attrs())
      learner = Fixtures.register_user("enrollment-paid-dup")

      assert {:ok, _} = create_enrollment(event, learner, %{tier_id: @paid_tier_id})
      assert {:error, _} = create_enrollment(event, learner, %{tier_id: @paid_tier_id})
    end

    test "cancel payment_pending：名额释放 + 可重新报名（R12）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{capacity: 1} |> Map.merge(paid_attrs()))

      learner = Fixtures.register_user("enrollment-paid-cancel")

      {:ok, enrollment} = create_enrollment(event, learner, %{tier_id: @paid_tier_id})

      assert {:ok, cancelled} =
               enrollment
               |> Ash.Changeset.for_update(:cancel, %{})
               |> Ash.update(tenant: workspace.id, actor: learner)

      assert cancelled.status == :cancelled
      assert EventFixtures.ledger_occupancy(event) == 0

      # 释放后可重新报名（计数回落再占位，重新拿回 1 号位）
      assert {:ok, re} = create_enrollment(event, learner, %{tier_id: @paid_tier_id})
      assert re.status == :payment_pending
      assert re.capacity_seq == 1
    end

    test "cancel payment_pending：同事务作废 pending 订单（cancel_reason=enrollment_cancelled，e2e #1）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, paid_attrs())
      learner = Fixtures.register_user("enrollment-paid-cancel-void")
      {:ok, enrollment} = create_enrollment(event, learner, %{tier_id: @paid_tier_id})
      order = create_pending_order(enrollment)
      assert pending_cents(workspace.id) == 9_900

      assert {:ok, cancelled} =
               enrollment
               |> Ash.Changeset.for_update(:cancel, %{})
               |> Ash.update(tenant: workspace.id, actor: learner)

      assert cancelled.status == :cancelled

      reloaded = Ash.get!(Order, order.id, tenant: workspace.id, authorize?: false)
      assert reloaded.status == :cancelled
      assert reloaded.cancel_reason == "enrollment_cancelled"
      # R24 待收只计 pending 未过期单——作废后回落
      assert pending_cents(workspace.id) == 0
    end
  end

  describe "waive_payment 免缴（R18，AE3 免缴半）" do
    setup do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, paid_attrs())
      learner = Fixtures.register_user("waive-learner")
      {:ok, enrollment} = create_enrollment(event, learner, %{tier_id: @paid_tier_id})

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

    test "免缴同事务作废 pending 订单：cancelled + cancel_reason=waived + 待收回落（e2e #1）", ctx do
      order = create_pending_order(ctx.enrollment)
      assert pending_cents(ctx.workspace.id) == 9_900

      assert {:ok, waived} = waive(ctx.enrollment, ctx.admin)
      assert waived.status == :confirmed

      reloaded = Ash.get!(Order, order.id, tenant: ctx.workspace.id, authorize?: false)
      assert reloaded.status == :cancelled
      assert reloaded.cancel_reason == "waived"
      # R24 待收只计 pending 未过期单——作废后回落
      assert pending_cents(ctx.workspace.id) == 0
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

  describe "关闭收费批量免费确认（organizer-payment U3，R9/AE1，KTD4）" do
    setup do
      admin = Fixtures.platform_admin("pricing-off-admin")
      workspace = Fixtures.create_workspace(admin)
      %{admin: admin, workspace: workspace}
    end

    test "AE1：3 已付不动、2 待付转免费确认 + 订单作废 + 审计行", ctx do
      event = EventFixtures.create_event(ctx.workspace, ctx.admin, paid_attrs())
      paid = for i <- 1..3, do: paid_enrollment(event, "off-paid-#{i}")
      pending = for i <- 1..2, do: pending_paid_enrollment(event, "off-pending-#{i}")

      assert {:ok, updated} = disable_pricing(event, ctx.admin)
      assert updated.pricing_enabled == false

      # 已付 3 笔：订单 paid、报名 confirmed 不动（R9 确认瞬间已支付者保持已付）
      for enrollment <- paid do
        reloaded = Ash.get!(Enrollment, enrollment.id, authorize?: false)
        assert reloaded.status == :confirmed
        assert reloaded.approved_by != ctx.admin.id
        assert reload_order_of(enrollment).status == :paid
      end

      # 待付 2 笔：confirmed + approved_by=操作者 + 订单 cancelled(waived)
      for enrollment <- pending do
        reloaded = Ash.get!(Enrollment, enrollment.id, authorize?: false)
        assert reloaded.status == :confirmed
        assert reloaded.approved_by == ctx.admin.id

        order = reload_order_of(enrollment)
        assert order.status == :cancelled
        assert order.cancel_reason == "waived"
      end

      # 每笔待付一条免缴审计行（落账兜底 waived? 判定依赖，KTD4 正确性约束）
      for enrollment <- pending do
        assert [%{action: :waive_payment, target_type: :enrollment}] =
                 Cgc2046.Repo.all(
                   from(log in Cgc2046.Accounts.AdminActionLog,
                     where: log.target_id == ^enrollment.id
                   )
                 )
      end

      # completed 信号补发（与单笔免缴同语义）
      for enrollment <- pending do
        assert count_enqueued("enrollment.completed", enrollment.id) == 1
      end
    end

    test "竞态：批量前某待付已被落账转确认 → 批量跳过该笔，订单保持已付", ctx do
      event = EventFixtures.create_event(ctx.workspace, ctx.admin, paid_attrs())
      settled = pending_paid_enrollment(event, "off-settled")
      other = pending_paid_enrollment(event, "off-other")

      # 落账先到：mark_paid + settle_paid（worker 同款两步）
      order = reload_order_of(settled)

      {:ok, _} =
        order
        |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "txn-race"})
        |> Ash.update(tenant: ctx.workspace.id, authorize?: false)

      {:ok, _} =
        settled
        |> Ash.Changeset.for_update(:settle_paid, %{})
        |> Ash.update(tenant: ctx.workspace.id, authorize?: false)

      assert {:ok, _} = disable_pricing(event, ctx.admin)

      # 先落账者保持已付（CAS 先到先得，KTD4 窗口语义）
      assert reload_order_of(settled).status == :paid
      refute_enqueued_for(settled)

      # 其余待付正常转换
      assert Ash.get!(Enrollment, other.id, authorize?: false).status == :confirmed
      assert reload_order_of(other).status == :cancelled
    end

    test "迟到支付：批量免缴后渠道迟到扣款 → 落账兜底自动原路退回", ctx do
      event = EventFixtures.create_event(ctx.workspace, ctx.admin, paid_attrs())
      pending = pending_paid_enrollment(event, "off-late")
      order = reload_order_of(pending)
      assert {:ok, _} = disable_pricing(event, ctx.admin)

      # 渠道迟到扣款（本地作废不关渠道单，QR 仍可被支付）
      Fake.script!(
        fetch_transaction:
          {:ok, %{status: :paid, amount_cents: 9_900, transaction_id: "txn-late"}}
      )

      assert :ok = perform_settlement(order)
      assert reload_order_of(pending).status == :refunding

      assert_enqueued(
        worker: Cgc2046.Payments.Workers.PaymentRefundWorker,
        args: %{"order_id" => order.id}
      )
    after
      Fake.reset!()
    end

    test "零副作用：免费活动编辑/开启收费/无报名关闭 全部不触发批量（AE4 回归面）", ctx do
      # 免费活动改标题：成功、零审计行
      free = EventFixtures.create_event(ctx.workspace, ctx.admin)

      assert {:ok, _} =
               free
               |> Ash.Changeset.for_update(:update, %{title: "改个标题"})
               |> Ash.update(tenant: ctx.workspace.id, actor: ctx.admin)

      assert waive_logs() == []

      # 收费活动零报名：关闭收费成功、零审计行
      empty = EventFixtures.create_event(ctx.workspace, ctx.admin, paid_attrs())
      assert {:ok, closed} = disable_pricing(empty, ctx.admin)
      assert waive_logs() == []

      # 开启方向（false→true）：无后端拦截（披露在前端，R16 语义）
      assert {:ok, reopened} =
               closed
               |> Ash.Changeset.for_update(:update, %{pricing_enabled: true})
               |> Ash.update(tenant: ctx.workspace.id, actor: ctx.admin)

      assert reopened.pricing_enabled == true
    end

    test "Course 同语义：关闭收费待付转确认 + 审计行", ctx do
      course = EventFixtures.create_course(ctx.workspace, ctx.admin, paid_attrs())
      pending = pending_paid_enrollment(course, "off-course")

      assert {:ok, _} = disable_pricing(course, ctx.admin)

      reloaded = Ash.get!(Enrollment, pending.id, authorize?: false)
      assert reloaded.status == :confirmed
      assert reloaded.approved_by == ctx.admin.id
      assert reload_order_of(pending).status == :cancelled

      assert [%{action: :waive_payment}] =
               Cgc2046.Repo.all(
                 from(log in Cgc2046.Accounts.AdminActionLog,
                   where: log.target_id == ^pending.id
                 )
               )
    end

    test "review F2：批量免缴后的迟到退款保留 confirmed 报名（钱退款坑保留）", ctx do
      event = EventFixtures.create_event(ctx.workspace, ctx.admin, paid_attrs())
      pending = pending_paid_enrollment(event, "f2-late")
      order = reload_order_of(pending)

      assert {:ok, _} = disable_pricing(event, ctx.admin)
      assert Ash.get!(Enrollment, pending.id, authorize?: false).status == :confirmed

      # 迟到扣款 → 作废单自动退款链（settlement → start_refund + 入队）
      Fake.script!(
        fetch_transaction: {:ok, %{status: :paid, amount_cents: 9_900, transaction_id: "txn-f2"}}
      )

      assert :ok = perform_settlement(order)
      assert reload_order_of(pending).status == :refunding

      # 退款 worker 收尾：钱退回，报名保持 confirmed（免缴占位不释放）
      Fake.script!(
        fetch_transaction:
          {:ok, %{status: :refunded, amount_cents: 9_900, transaction_id: "txn-f2-r"}}
      )

      assert :ok = perform_job(PaymentRefundWorker, %{"order_id" => order.id})
      assert reload_order_of(pending).status == :refunded

      reloaded = Ash.get!(Enrollment, pending.id, authorize?: false)
      assert reloaded.status == :confirmed
    after
      Fake.reset!()
    end

    test "review F5：批量免缴提交后新下单被拒（not_payment_pending 边界）", ctx do
      event = EventFixtures.create_event(ctx.workspace, ctx.admin, paid_attrs())
      pending = pending_paid_enrollment(event, "f5-barrier")

      assert {:ok, _} = disable_pricing(event, ctx.admin)

      # 免缴已确认：学员端再尝试下单（create_for_enrollment）必须被拒，
      # 不得插入新的 pending 订单（FOR UPDATE 锁内 status 重读裁决）
      learner = %{
        id: Ash.get!(Enrollment, pending.id, authorize?: false).user_id
      }

      assert {:error, error} =
               Order
               |> Ash.Changeset.for_create(:create_for_enrollment, %{
                 enrollment_id: pending.id,
                 provider: :wechat_native
               })
               |> Ash.create(tenant: ctx.workspace.id, actor: learner)

      assert %Ash.Error.Invalid{} = error
      assert Exception.message(error) =~ "not awaiting payment"

      # 无新订单落库
      assert reload_order_of(pending).status == :cancelled
    after
      Fake.reset!()
    end
  end

  describe "内容安全检查（plan 2026-08-18-009 P2 + advisor09 F1-F3：reason 提交链路同步拦截）" do
    @msg_check_url "https://api.weixin.qq.com/wxa/msg_sec_check"
    @openid "wx-openid-content-check"

    test "违规 reason（v2 risky）：create 拒绝且报名不落库（Repo 计数断言）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      learner = Fixtures.register_user("content-check-violation")
      attach_identity(learner, :wechat, @openid)

      Tesla.Mock.mock(fn
        %{method: :post, url: @msg_check_url <> _} ->
          Tesla.Mock.json(%{
            "errcode" => 0,
            "result" => %{"suggest" => "risky", "label" => 20002}
          })
      end)

      assert {:error, %Ash.Error.Invalid{errors: [error | _]}} =
               create_enrollment(event, learner, %{
                 submission_payload: %{"reason" => "某违规内容样例"}
               })

      assert %BusinessError{code: "enrollment_content_rejected"} = error
      refute Exception.message(error) =~ "某违规内容样例"
      assert enrollment_count(event.id) == 0
    end

    test "正常 reason（v2 pass）：通过检查并成功创建，请求体为 v2 形状含 openid" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      learner = Fixtures.register_user("content-check-pass")
      attach_identity(learner, :wechat, @openid)

      Tesla.Mock.mock(fn
        %{method: :post, url: @msg_check_url <> _} = env ->
          send(self(), {:msg_check_request, Jason.decode!(env.body)})
          Tesla.Mock.json(%{"errcode" => 0, "result" => %{"suggest" => "pass", "label" => 100}})
      end)

      assert {:ok, enrollment} =
               create_enrollment(event, learner, %{
                 submission_payload: %{"reason" => "很期待参加"}
               })

      assert enrollment.status == :confirmed

      assert_receive {:msg_check_request,
                      %{"content" => "很期待参加", "version" => 2, "scene" => 2, "openid" => @openid}}
    end

    test "tt 单平台 actor：跳过检查零外呼（未 mock 直接创建成功 = 结构性证明）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      learner = Fixtures.register_user("content-check-tt")
      attach_identity(learner, :tt, "tt-openid-content-check")

      # 不 mock msgSecCheck：若实现误发请求，Tesla.Mock 无匹配即 raise——零外呼证明。
      assert {:ok, enrollment} =
               create_enrollment(event, learner, %{
                 submission_payload: %{"reason" => "tt 平台内容不检查"}
               })

      assert enrollment.status == :confirmed
      refute_receive {:msg_check_request, _}
    end

    test "infra 故障 fail-open（D-2）：平台抖动不阻断报名，正常创建" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      learner = Fixtures.register_user("content-check-failopen")
      attach_identity(learner, :wechat, @openid)

      Tesla.Mock.mock(fn
        %{method: :post, url: @msg_check_url <> _} ->
          {:error, :timeout}
      end)

      assert {:ok, enrollment} =
               create_enrollment(event, learner, %{
                 submission_payload: %{"reason" => "平台瞬时故障也放行"}
               })

      assert enrollment.status == :confirmed
    end

    test "F3 reason 超 2500 字节（2400B 干净前缀 + 违规后缀整串）：服务端校验直接拒绝，不检查不外呼" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      learner = Fixtures.register_user("content-check-too-long")
      attach_identity(learner, :wechat, @openid)

      # 2400B 干净前缀（400×6B）+ 240B 违规后缀 = 2640B > 2500：整串拒绝，
      # 证明不是「截断前缀后仅查前缀」（那样 2400B 干净前缀会 pass）。
      reason = String.duplicate("干净", 400) <> String.duplicate("违规内容", 30)

      # 不 mock msgSecCheck：服务端校验在检查前拒绝，任何外呼都会 raise 暴露。
      assert {:error, %Ash.Error.Invalid{errors: [error | _]}} =
               create_enrollment(event, learner, %{
                 submission_payload: %{"reason" => reason}
               })

      assert %BusinessError{code: "enrollment_content_rejected"} = error
      assert enrollment_count(event.id) == 0
    end

    test "F3 reason 非 binary（array）：服务端校验直接拒绝，不检查不外呼" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      learner = Fixtures.register_user("content-check-array")

      assert {:error, %Ash.Error.Invalid{errors: [error | _]}} =
               create_enrollment(event, learner, %{
                 submission_payload: %{"reason" => ["a", "b"]}
               })

      assert %BusinessError{code: "enrollment_content_rejected"} = error
      assert enrollment_count(event.id) == 0
    end

    defp attach_identity(user, provider, uid) do
      UserIdentity
      |> Ash.Changeset.for_create(:upsert, %{
        provider: provider,
        uid: uid,
        user_id: user.id
      })
      |> Ash.create!(authorize?: false)
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

  # 免缴作废回归布置：为 payment_pending 报名挂一笔 pending 订单
  # （形状同 payment_settlement_worker_test 布置，渠道凭据字段由 provider 层测试覆盖）
  defp create_pending_order(enrollment) do
    {:ok, order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        enrollment_id: enrollment.id,
        provider: :wechat_native,
        out_trade_no: "oto-" <> Ecto.UUID.generate(),
        amount_cents: 9_900,
        tier_snapshot: %{"id" => @paid_tier_id, "name" => "早鸟", "amount_cents" => 9_900},
        expire_at: DateTime.add(DateTime.utc_now(), 2, :hour)
      })
      |> Ash.create(tenant: enrollment.workspace_id, authorize?: false)

    order
  end

  # R24 待收分量的 SQL 镜像（pending 且未过期）
  defp pending_cents(workspace_id) do
    %{rows: [[cents]]} =
      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        """
        SELECT COALESCE(SUM(amount_cents) FILTER (WHERE status = 'pending' AND expire_at > NOW()), 0)
        FROM payments_orders WHERE workspace_id = $1
        """,
        [Ecto.UUID.dump!(workspace_id)]
      )

    Decimal.to_integer(cents)
  end

  # 收费活动布置（U2 字段）：两档可售价位（首档固定 id，KTD9 收费报名必带 tierId）
  defp paid_attrs do
    %{
      pricing_enabled: true,
      price_tiers: [
        %{"id" => @paid_tier_id, "name" => "早鸟", "amount_cents" => 9900},
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

  # ── 关闭收费批量（U3）布置 ──

  # 已付报名：pending 订单 mark_paid + 报名 settle_paid（落账 worker 同款两步）
  defp paid_enrollment(target, suffix) do
    {:ok, enrollment} =
      create_enrollment(target, Fixtures.register_user(suffix), %{tier_id: @paid_tier_id})

    order = create_pending_order(enrollment)

    {:ok, _} =
      order
      |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "txn-" <> suffix})
      |> Ash.update(tenant: target.workspace_id, authorize?: false)

    {:ok, _} =
      enrollment
      |> Ash.Changeset.for_update(:settle_paid, %{})
      |> Ash.update(tenant: target.workspace_id, authorize?: false)

    enrollment
  end

  defp pending_paid_enrollment(target, suffix) do
    {:ok, enrollment} =
      create_enrollment(target, Fixtures.register_user(suffix), %{tier_id: @paid_tier_id})

    _order = create_pending_order(enrollment)
    enrollment
  end

  defp disable_pricing(target, actor) do
    target
    |> Ash.Changeset.for_update(:update, %{pricing_enabled: false})
    |> Ash.update(tenant: target.workspace_id, actor: actor)
  end

  defp reload_order_of(enrollment) do
    require Ash.Query
    enrollment_id = enrollment.id

    Order
    |> Ash.Query.filter(enrollment_id == ^enrollment_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp waive_logs do
    Cgc2046.Repo.all(
      from(log in Cgc2046.Accounts.AdminActionLog, where: log.action == :waive_payment)
    )
  end

  # settlement worker 同码入口（与 payment_settlement_worker_test.perform_settlement
  # 同形状）：webhook_event 布置 + perform_job
  defp perform_settlement(order) do
    require Ash.Query

    event_id = "evt-" <> order.out_trade_no

    event =
      WebhookEvent
      |> Ash.Query.filter(event_id == ^event_id)
      |> Ash.read_one!(authorize?: false)
      |> case do
        nil ->
          WebhookEvent
          |> Ash.Changeset.for_create(:create, %{
            provider: :wechat,
            event_id: event_id,
            payload: %{"out_trade_no" => order.out_trade_no}
          })
          |> Ash.create!(authorize?: false)

        existing ->
          existing
      end

    perform_job(PaymentSettlementWorker, %{"webhook_event_id" => event.id})
  end

  defp refute_enqueued_for(enrollment) do
    order = reload_order_of(enrollment)

    assert [] =
             all_enqueued(worker: PaymentRefundWorker)
             |> Enum.filter(&(&1.args["order_id"] == order.id))
  end
end
