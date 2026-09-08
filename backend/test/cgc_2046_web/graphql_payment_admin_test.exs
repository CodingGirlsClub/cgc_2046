defmodule Cgc2046Web.GraphqlPaymentAdminTest do
  @moduledoc """
  U10：管理查询 + 收款统计 + 通知模板接线（R22/R24）。

  - 管理列表：Owner/Admin 可读本租户（含 tier/报名人信息）；普通成员 403；
    PlatformAdmin 跨租户只读。
  - stats 三分量：3 paid + 1 pending（未过期）+ 1 refunded；过期 pending 单
    不计待收（U8 释放语义）。
  - 三模板端到端：支付成功 → 报名人；退款成功 → 报名人 + 发起管理员
    （R22 精确归属，非发起的其他管理者不收）；退款失败 → 同两人。
  """

  use Cgc2046Web.ConnCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Payments.WebhookEvent
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Payments.{NotificationTemplates, Order}
  alias Cgc2046.Payments.Providers.Fake
  alias Cgc2046.Notifications.NotificationWorker
  alias Cgc2046.Payments.Workers.PaymentRefundWorker
  alias Cgc2046.Payments.Workers.PaymentSettlementWorker

  @tier_id "77777777-7777-7777-7777-777777777777"
  @tier %{"id" => @tier_id, "name" => "标准档", "amount_cents" => 19_900}

  describe "workspaceOrders 管理列表（R24）" do
    test "Owner/Admin 可读本租户（含 tier/报名人信息）；成员 403；PlatformAdmin 跨租户可读" do
      %{owner: owner, member: member, workspace: workspace} = managed_workspace()

      admin = Fixtures.register_user("pay-admin")
      Fixtures.add_member(workspace, admin, [:admin])

      platform = Fixtures.platform_admin("pay-platform")
      learner = paid_enrollment(workspace, owner, "list-paid")

      query = orders_query(workspace.id)

      # Owner：本租户 + tier 快照名 + 报名人邮箱（calc 信息面）
      assert [%{"status" => "paid", "tierName" => "标准档"} = row] =
               results(graphql(query, sign_in_token(owner)))

      assert row["learnerEmail"] == to_string(learner.email)
      assert row["enrollmentStatus"] != nil

      # Workspace Admin
      assert [%{"status" => "paid"}] = results(graphql(query, sign_in_token(admin)))

      # 普通成员 403（不泄露数据面）
      assert [%{"message" => _}] = gql_errors(graphql(query, sign_in_token(member)))

      # PlatformAdmin 跨租户只读（R19/R24）
      assert [%{"status" => "paid"}] = results(graphql(query, sign_in_token(platform)))
    end
  end

  describe "workspacePaymentStats 三分量（R24）" do
    test "3 paid + 1 pending（未过期）+ 1 refunded；过期 pending 不计待收" do
      %{owner: owner, workspace: workspace} = managed_workspace()

      # 3 paid
      for i <- 1..3, do: paid_enrollment(workspace, owner, "stats-paid-#{i}")
      # 1 pending 未过期（计待收）
      pending_enrollment(workspace, owner, "stats-pending")
      # 1 pending 已过期（U8 释放语义，不计待收）
      expired_pending_enrollment(workspace, owner, "stats-expired")
      # 1 refunded
      refunded_enrollment(workspace, owner, "stats-refunded")

      assert %{"data" => %{"workspacePaymentStats" => raw}} =
               graphql(stats_query(workspace.id), sign_in_token(owner))

      # JsonString 标量：JSON 编码字符串（KTD9 契约，U11 手写解析）
      stats = raw |> Jason.decode!() |> Map.new(fn {k, v} -> {k, as_int(v)} end)

      assert stats["collected_cents"] == 3 * 19_900
      assert stats["pending_cents"] == 19_900
      assert stats["refunded_cents"] == 19_900
      # U1-R1 第四分量：无 refund_failed 单时为 0
      assert stats["refund_failed_cents"] == 0

      # 普通成员不可读统计
      member = Fixtures.register_user("stats-member")
      Fixtures.add_member(workspace, member, [:member])

      assert [%{"message" => _}] =
               gql_errors(graphql(stats_query(workspace.id), sign_in_token(member)))
    end
  end

  describe "订单活动维度（organizer-payment U4，KTD2/KTD3）" do
    test "workspaceOrders 按 eventId/courseId 筛选只回该活动订单" do
      %{owner: owner, workspace: workspace} = managed_workspace()

      event_a = paid_event(workspace, owner)
      event_b = paid_event(workspace, owner)

      course_c =
        EventFixtures.create_course(workspace, owner, %{
          pricing_enabled: true,
          price_tiers: [@tier]
        })

      _learner_a1 = paid_enrollment_in(event_a, workspace, owner, "off-a1")
      _learner_a2 = pending_enrollment_in(event_a, workspace, owner, "off-a2")
      _learner_b = paid_enrollment_in(event_b, workspace, owner, "off-b1")
      _learner_c = paid_enrollment_in(course_c, workspace, owner, "off-c1")

      # eventId 筛选：只回 event_a 的两单（paid + pending）
      assert rows =
               results(
                 graphql(orders_query_with_event(workspace.id, event_a.id), sign_in_token(owner))
               )

      assert length(rows) == 2
      assert Enum.sort(Enum.map(rows, & &1["status"])) == ["paid", "pending"]

      # courseId 筛选：只回 course_c 的一单
      assert [%{"status" => "paid"}] =
               results(
                 graphql(
                   orders_query_with_course(workspace.id, course_c.id),
                   sign_in_token(owner)
                 )
               )
    end

    test "workspacePaymentStats 带 offering 参数：口径与全工作区同源" do
      %{owner: owner, workspace: workspace} = managed_workspace()

      event_a = paid_event(workspace, owner)
      _b = paid_enrollment_in(paid_event(workspace, owner), workspace, owner, "stats2-b")
      paid_enrollment_in(event_a, workspace, owner, "stats2-a1")
      pending_enrollment_in(event_a, workspace, owner, "stats2-a2")

      scoped =
        graphql(stats_query_with_event(workspace.id, event_a.id), sign_in_token(owner))

      assert %{"data" => %{"workspacePaymentStats" => raw}} = scoped
      stats = raw |> Jason.decode!() |> Map.new(fn {k, v} -> {k, as_int(v)} end)
      assert stats["collected_cents"] == 19_900
      assert stats["pending_cents"] == 19_900
      assert stats["refunded_cents"] == 0

      # 全工作区口径（2 paid + 1 pending）
      assert %{"data" => %{"workspacePaymentStats" => raw_all}} =
               graphql(stats_query(workspace.id), sign_in_token(owner))

      all = raw_all |> Jason.decode!() |> Map.new(fn {k, v} -> {k, as_int(v)} end)
      assert all["collected_cents"] == 2 * 19_900
      assert all["pending_cents"] == 19_900
    end

    test "workspacePaymentStats 跨类误传：course UUID 传入 eventId 返回零,不归并 course 金额(PR⑤ peer#2 钉测)" do
      %{owner: owner, workspace: workspace} = managed_workspace()

      course_c =
        EventFixtures.create_course(workspace, owner, %{
          pricing_enabled: true,
          price_tiers: [@tier]
        })

      _learner_c = paid_enrollment_in(course_c, workspace, owner, "cross-c1")

      # course UUID 误传入 eventId:event 侧无此供给物,必须零值而非归并 course 统计
      assert %{"data" => %{"workspacePaymentStats" => raw}} =
               graphql(stats_query_with_event(workspace.id, course_c.id), sign_in_token(owner))

      stats = raw |> Jason.decode!() |> Map.new(fn {k, v} -> {k, as_int(v)} end)
      assert stats["collected_cents"] == 0
      assert stats["pending_cents"] == 0

      # 正确入参 courseId 仍能取到 course 统计
      assert %{"data" => %{"workspacePaymentStats" => raw_c}} =
               graphql(stats_query_with_course(workspace.id, course_c.id), sign_in_token(owner))

      stats_c = raw_c |> Jason.decode!() |> Map.new(fn {k, v} -> {k, as_int(v)} end)
      assert stats_c["collected_cents"] == 19_900
    end

    test "retryRefund 两段确认：首调建 pending 不落库，confirm 后 refund_failed → refunding + job 入队；paid 被拒；权限矩阵" do
      %{owner: owner, member: member, admin: admin, workspace: workspace} = managed_workspace()

      platform = Fixtures.platform_admin("retry-platform")
      learner = refund_failed_enrollment(workspace, owner, "retry-failed")
      order_id = order_id_of(enrollment_id_of(learner))

      # 普通成员：读权门即拦截（read policy 过滤后同 not_found，不泄露订单存在性）
      assert [%{"code" => "not_found"}] =
               payload_errors(
                 graphql(retry_mutation(order_id), sign_in_token(member)),
                 "retryRefund"
               )

      # paid 单首调即状态快速失败（不建 pending）
      paid_learner = paid_enrollment(workspace, owner, "retry-paid")
      paid_order_id = order_id_of(enrollment_id_of(paid_learner))

      assert [%{"code" => "order_already_processed"}] =
               payload_errors(
                 graphql(retry_mutation(paid_order_id), sign_in_token(owner)),
                 "retryRefund"
               )

      # Owner 首调：建 pending 返回后端摘要，不落业务库（仍 refund_failed、无退款 job）
      assert %{
               "data" => %{
                 "retryRefund" => %{
                   "pendingId" => pending_id,
                   "summary" => summary,
                   "errors" => []
                 }
               }
             } = graphql(retry_mutation(order_id), sign_in_token(owner))

      assert summary =~ "重试退款"
      assert Ash.get!(Order, order_id, authorize?: false).status == :refund_failed
      refute_enqueued(worker: PaymentRefundWorker)

      # confirm 后真正执行：refunding + job 入队（发起人随 job 下传）
      assert %{"data" => %{"confirmOperation" => %{"status" => "confirmed", "errors" => []}}} =
               graphql(confirm_mutation(pending_id), sign_in_token(owner))

      assert Ash.get!(Order, order_id, authorize?: false).status == :refunding

      assert_enqueued(
        worker: PaymentRefundWorker,
        args: %{"order_id" => order_id, "initiator_user_id" => owner.id}
      )

      # Admin / PlatformAdmin 同权（首调过管理权预检；paid 单止于状态预检，证明已过授权门）
      assert [%{"code" => "order_already_processed"}] =
               payload_errors(
                 graphql(retry_mutation(paid_order_id), sign_in_token(admin)),
                 "retryRefund"
               )

      assert [%{"code" => "order_already_processed"}] =
               payload_errors(
                 graphql(retry_mutation(paid_order_id), sign_in_token(platform)),
                 "retryRefund"
               )
    end
  end

  describe "支付操作两段确认流（web 面 R2 对齐：无 confirm 不落业务库）" do
    test "platform_admin 跨租户 refundOrder：首调只建 pending；confirm 后 CAS/审计/worker 路径不变" do
      %{owner: owner, workspace: workspace} = managed_workspace()
      platform = Fixtures.platform_admin("refund-platform")
      learner = paid_enrollment(workspace, owner, "refund-target")
      order_id = order_id_of(enrollment_id_of(learner))

      # 首调：PlatformAdmin 跨租户有退款兜底权（R19）可发起——但只建 pending，
      # 不落业务库：订单仍 paid、无退款 job、无审计行；摘要由后端生成
      assert %{
               "data" => %{
                 "refundOrder" => %{
                   "pendingId" => pending_id,
                   "summary" => summary,
                   "errors" => []
                 }
               }
             } = graphql(refund_mutation(order_id), sign_in_token(platform))

      assert summary =~ "退款 ¥199.00"
      assert Ash.get!(Order, order_id, authorize?: false).status == :paid
      refute_enqueued(worker: PaymentRefundWorker)
      assert admin_action_logs(:order_refund) == []

      # confirm：真正执行——CAS paid → refunding + 退款 job 入队 + LogAdminAction 审计
      assert %{"data" => %{"confirmOperation" => %{"status" => "confirmed", "errors" => []}}} =
               graphql(confirm_mutation(pending_id), sign_in_token(platform))

      assert Ash.get!(Order, order_id, authorize?: false).status == :refunding

      assert_enqueued(
        worker: PaymentRefundWorker,
        args: %{"order_id" => order_id, "initiator_user_id" => platform.id}
      )

      assert [%{action: :order_refund, actor_id: actor_id}] = admin_action_logs(:order_refund)
      assert actor_id == platform.id
    end

    test "cancelOperation：取消后不执行（订单仍 paid、无 job）；取消后再 confirm 被拒" do
      %{owner: owner, workspace: workspace} = managed_workspace()
      learner = paid_enrollment(workspace, owner, "cancel-target")
      order_id = order_id_of(enrollment_id_of(learner))

      assert %{"data" => %{"refundOrder" => %{"pendingId" => pending_id, "errors" => []}}} =
               graphql(refund_mutation(order_id), sign_in_token(owner))

      assert %{"data" => %{"cancelOperation" => %{"status" => "cancelled", "errors" => []}}} =
               graphql(cancel_mutation(pending_id), sign_in_token(owner))

      assert Ash.get!(Order, order_id, authorize?: false).status == :paid
      refute_enqueued(worker: PaymentRefundWorker)

      # 取消后同 pending 不可再 confirm（状态机 cancelled 终态）
      assert %{
               "data" => %{
                 "confirmOperation" => %{
                   "status" => nil,
                   "errors" => [%{"code" => "operation_confirm_failed"}]
                 }
               }
             } = graphql(confirm_mutation(pending_id), sign_in_token(owner))

      assert Ash.get!(Order, order_id, authorize?: false).status == :paid
      refute_enqueued(worker: PaymentRefundWorker)
    end

    test "过期 pending 拒绝确认（expires_at 过后读时派生 expired）" do
      %{owner: owner, workspace: workspace} = managed_workspace()
      learner = paid_enrollment(workspace, owner, "expired-target")
      order_id = order_id_of(enrollment_id_of(learner))

      assert %{"data" => %{"refundOrder" => %{"pendingId" => pending_id, "errors" => []}}} =
               graphql(refund_mutation(order_id), sign_in_token(owner))

      # expires_at 直接拨到过去（读时派生 expired；async 测试不动全局 TTL env）
      Cgc2046.Repo.query!(
        "UPDATE mcp_pending_operations SET expires_at = NOW() - interval '1 minute' WHERE id = $1",
        [Ecto.UUID.dump!(pending_id)]
      )

      assert %{
               "data" => %{
                 "confirmOperation" => %{
                   "status" => nil,
                   "errors" => [%{"code" => "operation_confirm_failed"}]
                 }
               }
             } = graphql(confirm_mutation(pending_id), sign_in_token(owner))

      assert Ash.get!(Order, order_id, authorize?: false).status == :paid
      refute_enqueued(worker: PaymentRefundWorker)
    end

    test "pending 仅本人可确认/取消（同工作台另一管理员一律 not found，不泄露存在性）" do
      %{owner: owner, admin: admin, workspace: workspace} = managed_workspace()
      learner = paid_enrollment(workspace, owner, "ownership-target")
      order_id = order_id_of(enrollment_id_of(learner))

      assert %{"data" => %{"refundOrder" => %{"pendingId" => pending_id, "errors" => []}}} =
               graphql(refund_mutation(order_id), sign_in_token(owner))

      assert %{
               "data" => %{
                 "confirmOperation" => %{
                   "errors" => [
                     %{
                       "code" => "operation_confirm_failed",
                       "message" => "pending operation not found"
                     }
                   ]
                 }
               }
             } = graphql(confirm_mutation(pending_id), sign_in_token(admin))

      assert %{
               "data" => %{
                 "cancelOperation" => %{
                   "errors" => [%{"code" => "operation_cancel_failed"}]
                 }
               }
             } = graphql(cancel_mutation(pending_id), sign_in_token(admin))

      # 本人 confirm 仍可用
      assert %{"data" => %{"confirmOperation" => %{"status" => "confirmed", "errors" => []}}} =
               graphql(confirm_mutation(pending_id), sign_in_token(owner))

      assert Ash.get!(Order, order_id, authorize?: false).status == :refunding
    end

    test "双确认：第二次 confirm 同 pending 被拒（confirmed 终态不可重复执行）" do
      %{owner: owner, workspace: workspace} = managed_workspace()
      learner = paid_enrollment(workspace, owner, "double-confirm-target")
      order_id = order_id_of(enrollment_id_of(learner))

      assert %{"data" => %{"refundOrder" => %{"pendingId" => pending_id, "errors" => []}}} =
               graphql(refund_mutation(order_id), sign_in_token(owner))

      assert %{"data" => %{"confirmOperation" => %{"status" => "confirmed", "errors" => []}}} =
               graphql(confirm_mutation(pending_id), sign_in_token(owner))

      assert %{
               "data" => %{
                 "confirmOperation" => %{
                   "status" => nil,
                   "errors" => [%{"code" => "operation_confirm_failed"}]
                 }
               }
             } = graphql(confirm_mutation(pending_id), sign_in_token(owner))

      # 退款 job 只入队一次（无重复退款）
      assert length(all_enqueued(worker: PaymentRefundWorker)) == 1
    end

    test "waivePayment 两段：首调报名仍 payment_pending；confirm 后 confirmed + 关联订单作废 + 审计" do
      %{owner: owner, workspace: workspace} = managed_workspace()
      learner = pending_enrollment(workspace, owner, "waive-target")
      enrollment_id = enrollment_id_of(learner)
      order = order_of(learner)

      assert Ash.get!(Enrollment, enrollment_id, authorize?: false).status == :payment_pending

      # 首调：只建 pending，报名/订单不变；摘要由后端生成
      assert %{
               "data" => %{
                 "waivePayment" => %{
                   "pendingId" => pending_id,
                   "summary" => summary,
                   "errors" => []
                 }
               }
             } = graphql(waive_mutation(enrollment_id), sign_in_token(owner))

      assert summary =~ "免缴"
      assert Ash.get!(Enrollment, enrollment_id, authorize?: false).status == :payment_pending
      assert Ash.get!(Order, order.id, authorize?: false).status == :pending
      assert admin_action_logs(:waive_payment) == []

      # confirm：payment_pending → confirmed + 关联 pending 订单作废 + 审计 :waive_payment
      assert %{"data" => %{"confirmOperation" => %{"status" => "confirmed", "errors" => []}}} =
               graphql(confirm_mutation(pending_id), sign_in_token(owner))

      assert Ash.get!(Enrollment, enrollment_id, authorize?: false).status == :confirmed
      assert Ash.get!(Order, order.id, authorize?: false).status == :cancelled
      assert [%{action: :waive_payment, actor_id: actor_id}] = admin_action_logs(:waive_payment)
      assert actor_id == owner.id
    end
  end

  describe "三通知模板端到端（R22/KTD8 定稿）" do
    test "模板 registry 三键已配（config 契约定稿）" do
      registry = Application.get_env(:cgc_2046, :miniprogram_templates, %{})

      for platform <- [:wechat, :tt, :xhs],
          key <- [
            NotificationTemplates.payment_succeeded(),
            NotificationTemplates.refund_succeeded(),
            NotificationTemplates.refund_failed()
          ] do
        assert entry = get_in(registry, [platform, key])
        assert is_binary(entry) and entry != ""
      end
    end

    test "支付成功 → payment_succeeded（报名人）；退款成功 → 报名人 + 发起管理员（精确）" do
      %{owner: owner, workspace: workspace} = managed_workspace()
      initiator = Fixtures.register_user("refund-initiator")
      Fixtures.add_member(workspace, initiator, [:admin])

      # 支付链：报名 → 下单（graphql）→ 渠道回查 paid → 落账 worker → 通知
      learner = Fixtures.register_user("tpl-learner")
      insert_identity(learner.id, :wechat, "tpl-learner-openid")
      enrollment = enroll(workspace, learner, owner)

      assert %{"data" => %{"createOrder" => %{"result" => %{"id" => order_id}}}} =
               graphql(order_mutation(enrollment.id, "wechat_native"), sign_in_token(learner))

      Fake.script!(
        fetch_transaction:
          {:ok, %{status: :paid, amount_cents: 19_900, transaction_id: "txn-tpl-1"}}
      )

      assert :ok = perform_settlement(order_id)

      assert [paid_notification] =
               notifications_for(NotificationTemplates.payment_succeeded())
               |> Enum.filter(&(&1.args["user_id"] == learner.id))

      assert paid_notification.args["data"]["amount"] == "199.00"
      assert paid_notification.args["data"]["order_id"] == order_id

      Fake.reset!()

      # 退款链：initiator（Admin，非 Owner）经 mutation 发起 → job 携带发起人 →
      # worker 收尾 → 收件人精确 = 报名人 + 发起管理员（R22），Owner 不收。
      insert_identity(initiator.id, :wechat, "refund-initiator-openid")

      Fake.script!(
        fetch_transaction:
          {:ok, %{status: :refunded, amount_cents: 19_900, transaction_id: "txn-tpl-1"}}
      )

      # 两段确认：首调建 pending，confirm 才真正发起退款（initiator 两段同操作）
      assert %{"data" => %{"refundOrder" => %{"pendingId" => pending_id, "errors" => []}}} =
               graphql(refund_mutation(order_id), sign_in_token(initiator))

      assert %{"data" => %{"confirmOperation" => %{"status" => "confirmed", "errors" => []}}} =
               graphql(confirm_mutation(pending_id), sign_in_token(initiator))

      assert_enqueued(
        worker: PaymentRefundWorker,
        args: %{"order_id" => order_id, "initiator_user_id" => initiator.id}
      )

      assert :ok =
               perform_job(PaymentRefundWorker, %{
                 "order_id" => order_id,
                 "initiator_user_id" => initiator.id
               })

      refund_notifs = notifications_for(NotificationTemplates.refund_succeeded())

      recipient_ids = refund_notifs |> Enum.map(& &1.args["user_id"]) |> Enum.uniq()
      assert Enum.sort(recipient_ids) == Enum.sort([learner.id, initiator.id])

      # Owner（其他管理者）不在精确收件面
      refute Enum.any?(refund_notifs, &(&1.args["user_id"] == owner.id))

      # 报名取消 + 名额释放（退款即取消联动回归）
      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :cancelled
    after
      Fake.reset!()
    end

    test "渠道拒绝 → refund_failed（报名人 + 发起管理员）" do
      %{workspace: workspace} = managed_workspace()
      initiator = Fixtures.register_user("refund-failed-initiator")
      Fixtures.add_member(workspace, initiator, [:admin])

      learner = paid_enrollment(workspace, initiator, "tpl-failed")
      insert_identity(learner.id, :wechat, "refund-failed-learner-openid")
      insert_identity(initiator.id, :wechat, "refund-failed-initiator-openid")

      order = order_of(learner)
      order_id = order.id

      Fake.script!(refund: {:error, :channel_refund_failed})

      assert {:ok, _} =
               order
               |> Ash.Changeset.for_update(:refund, %{})
               |> Ash.update(tenant: workspace.id, actor: initiator)

      assert :ok =
               perform_job(PaymentRefundWorker, %{
                 "order_id" => order_id,
                 "initiator_user_id" => initiator.id
               })

      failed_notifs = notifications_for(NotificationTemplates.refund_failed())

      recipient_ids = failed_notifs |> Enum.map(& &1.args["user_id"]) |> Enum.uniq()
      assert Enum.sort(recipient_ids) == Enum.sort([learner.id, initiator.id])
    after
      Fake.reset!()
    end
  end

  # ── 布置 ──

  defp managed_workspace do
    %{owner: owner, member: member, workspace: workspace} = Fixtures.workspace_with_member()
    admin = Fixtures.register_user("gql-pay-admin")
    Fixtures.add_member(workspace, admin, [:admin])
    %{owner: owner, member: member, admin: admin, workspace: workspace}
  end

  defp paid_event(workspace, creator) do
    EventFixtures.create_event(workspace, creator, %{
      pricing_enabled: true,
      price_tiers: [@tier]
    })
  end

  defp enroll(workspace, learner, creator) do
    event = paid_event(workspace, creator)

    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{
        event_id: event.id,
        user_id: learner.id,
        tier_id: @tier_id
      })
      |> Ash.create(tenant: workspace.id, actor: learner)

    enrollment
  end

  # 单 paid 链：报名（payment_pending）+ paid 订单 + 落账（confirmed）
  defp paid_enrollment(workspace, creator, suffix) do
    learner = Fixtures.register_user("u10-#{suffix}-#{uniq()}")
    enrollment = enroll(workspace, learner, creator)

    {:ok, order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        enrollment_id: enrollment.id,
        provider: :wechat_native,
        out_trade_no: "oto-" <> Ecto.UUID.generate(),
        amount_cents: 19_900,
        tier_snapshot: @tier,
        expire_at: DateTime.add(DateTime.utc_now(), 2, :hour)
      })
      |> Ash.create(tenant: workspace.id, authorize?: false)

    {:ok, _} =
      order
      |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "txn-#{uniq()}"})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    {:ok, _} =
      enrollment
      |> Ash.Changeset.for_update(:settle_paid, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    learner
  end

  defp pending_enrollment(workspace, creator, suffix) do
    enrollment_of_pending(workspace, creator, suffix, DateTime.add(DateTime.utc_now(), 1, :hour))
  end

  defp expired_pending_enrollment(workspace, creator, suffix) do
    enrollment_of_pending(workspace, creator, suffix, DateTime.add(DateTime.utc_now(), -1, :hour))
  end

  defp enrollment_of_pending(workspace, creator, suffix, expire_at) do
    learner = Fixtures.register_user("u10-#{suffix}-#{uniq()}")
    enrollment = enroll(workspace, learner, creator)
    insert_order(workspace, enrollment, expire_at)
    learner
  end

  defp refunded_enrollment(workspace, creator, suffix) do
    learner = paid_enrollment(workspace, creator, suffix)

    {:ok, refunding} =
      order_of(learner)
      |> Ash.Changeset.for_update(:start_refund, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    {:ok, _} =
      refunding
      |> Ash.Changeset.for_update(:refund_succeeded, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    learner
  end

  defp insert_order(workspace, enrollment, expire_at) do
    {:ok, order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        enrollment_id: enrollment.id,
        provider: :wechat_native,
        out_trade_no: "oto-" <> Ecto.UUID.generate(),
        amount_cents: 19_900,
        tier_snapshot: @tier,
        expire_at: expire_at
      })
      |> Ash.create(tenant: workspace.id, authorize?: false)

    order
  end

  defp order_of(learner) do
    require Ash.Query

    Order
    |> Ash.Query.filter(enrollment_id == ^enrollment_id_of(learner))
    |> Ash.read_one!(authorize?: false)
  end

  defp order_id_of(enrollment_id) do
    require Ash.Query

    Order
    |> Ash.Query.filter(enrollment_id == ^enrollment_id)
    |> Ash.read_one!(authorize?: false)
    |> Map.fetch!(:id)
  end

  defp enrollment_id_of(learner) do
    require Ash.Query

    Enrollment
    |> Ash.Query.filter(user_id == ^learner.id)
    |> Ash.read_one!(authorize?: false)
    |> Map.fetch!(:id)
  end

  defp perform_settlement(order_id) do
    require Ash.Query

    order = Ash.get!(Order, order_id, authorize?: false)
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
            event_id: "evt-" <> order.out_trade_no,
            payload: %{"out_trade_no" => order.out_trade_no}
          })
          |> Ash.create!(authorize?: false)

        existing ->
          existing
      end

    perform_job(PaymentSettlementWorker, %{
      "webhook_event_id" => event.id,
      "provider" => "wechat"
    })
  end

  defp notifications_for(template_key) do
    all_enqueued(worker: NotificationWorker)
    |> Enum.filter(&(&1.args["template_key"] == template_key))
  end

  defp insert_identity(user_id, provider, uid) do
    Cgc2046.Repo.query!(
      """
      INSERT INTO user_identities (id, provider, uid, user_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $2, $3, NOW(), NOW())
      """,
      [to_string(provider), uid, Ecto.UUID.dump!(user_id)]
    )
  end

  # ── GraphQL 文档 ──

  defp orders_query(workspace_id) do
    """
    { workspaceOrders(workspaceId: "#{workspace_id}") { results { id status tierName learnerEmail enrollmentStatus amountCents } } }
    """
  end

  # ── U4 helpers ──

  defp orders_query_with_event(workspace_id, event_id) do
    """
    { workspaceOrders(workspaceId: "#{workspace_id}", filter: {eventId: {eq: "#{event_id}"}}) { results { id status } } }
    """
  end

  defp orders_query_with_course(workspace_id, course_id) do
    """
    { workspaceOrders(workspaceId: "#{workspace_id}", filter: {courseId: {eq: "#{course_id}"}}) { results { id status } } }
    """
  end

  defp stats_query_with_event(workspace_id, event_id) do
    """
    { workspacePaymentStats(workspaceId: "#{workspace_id}", eventId: "#{event_id}") }
    """
  end

  defp stats_query_with_course(workspace_id, course_id) do
    """
    { workspacePaymentStats(workspaceId: "#{workspace_id}", courseId: "#{course_id}") }
    """
  end

  defp retry_mutation(order_id) do
    """
    mutation {
      retryRefund(id: "#{order_id}") {
        pendingId
        summary
        errors { message code }
      }
    }
    """
  end

  defp waive_mutation(enrollment_id) do
    """
    mutation {
      waivePayment(id: "#{enrollment_id}") {
        pendingId
        summary
        errors { message code }
      }
    }
    """
  end

  defp confirm_mutation(pending_id) do
    """
    mutation {
      confirmOperation(pendingId: "#{pending_id}") {
        pendingId
        status
        errors { message code }
      }
    }
    """
  end

  defp cancel_mutation(pending_id) do
    """
    mutation {
      cancelOperation(pendingId: "#{pending_id}") {
        pendingId
        status
        errors { message code }
      }
    }
    """
  end

  # 定目标报名（共享同一 event/course 的布置基础）
  defp enroll_in(target, workspace, learner) do
    target_key = if target.__struct__ == Cgc2046.Events.Event, do: :event_id, else: :course_id

    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{
        target_key => target.id,
        user_id: learner.id,
        tier_id: @tier_id
      })
      |> Ash.create(tenant: workspace.id, actor: learner)

    enrollment
  end

  defp paid_enrollment_in(target, workspace, _creator, _suffix) do
    learner = Fixtures.register_user("u4-#{uniq()}")
    enrollment = enroll_in(target, workspace, learner)

    {:ok, order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        enrollment_id: enrollment.id,
        provider: :wechat_native,
        out_trade_no: "oto-" <> Ecto.UUID.generate(),
        amount_cents: 19_900,
        tier_snapshot: @tier,
        expire_at: DateTime.add(DateTime.utc_now(), 2, :hour)
      })
      |> Ash.create(tenant: workspace.id, authorize?: false)

    {:ok, _} =
      order
      |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "txn-#{uniq()}"})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    {:ok, _} =
      enrollment
      |> Ash.Changeset.for_update(:settle_paid, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    learner
  end

  defp pending_enrollment_in(target, workspace, _creator, _suffix) do
    learner = Fixtures.register_user("u4-#{uniq()}")
    enrollment = enroll_in(target, workspace, learner)
    insert_order(workspace, enrollment, DateTime.add(DateTime.utc_now(), 1, :hour))
    learner
  end

  defp refund_failed_enrollment(workspace, creator, suffix) do
    learner = paid_enrollment(workspace, creator, suffix)

    {:ok, refunding} =
      order_of(learner)
      |> Ash.Changeset.for_update(:start_refund, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    {:ok, _} =
      refunding
      |> Ash.Changeset.for_update(:mark_refund_failed, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    learner
  end

  defp stats_query(workspace_id) do
    """
    { workspacePaymentStats(workspaceId: "#{workspace_id}") }
    """
  end

  defp order_mutation(enrollment_id, provider) do
    """
    mutation {
      createOrder(input: {enrollmentId: "#{enrollment_id}", provider: "#{provider}"}) {
        result { id }
        errors { message }
      }
    }
    """
  end

  defp refund_mutation(order_id) do
    """
    mutation {
      refundOrder(id: "#{order_id}") {
        pendingId
        summary
        errors { message code }
      }
    }
    """
  end

  # ── 响应取值 ──

  defp results(response) do
    case response do
      %{"data" => %{"workspaceOrders" => %{"results" => results}}} -> results
      %{"errors" => errors} -> flunk("query failed: #{inspect(errors)}")
      _ -> []
    end
  end

  # 两段确认 mutation 的业务错误在 payload errors 通道（与自动 mutation 同款）；
  # 顶层 errors（未登录等）一并覆盖
  defp payload_errors(response, key) do
    case response do
      %{"errors" => errors} -> errors
      %{"data" => %{^key => %{"errors" => errors}}} -> errors
    end
  end

  defp gql_errors(response) do
    case response do
      %{"errors" => errors} -> errors
      _ -> []
    end
  end

  defp admin_action_logs(action) do
    require Ecto.Query

    Cgc2046.Repo.all(
      Ecto.Query.from(log in Cgc2046.Accounts.AdminActionLog, where: log.action == ^action)
    )
  end

  defp sign_in_token(user) do
    mutation = """
    mutation {
      signIn(login: "#{user.email}", password: "#{Fixtures.password()}") { id }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => mutation})

    assert %{"data" => %{"signIn" => %{"id" => _}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  defp graphql(query, token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end

  defp uniq, do: String.slice(Ecto.UUID.generate(), 0, 8)

  defp as_int(value) when is_integer(value), do: value
  defp as_int(value) when is_binary(value), do: String.to_integer(value)
end
