defmodule Cgc2046.Payments.Workers.PaymentExpiryWorkerTest do
  @moduledoc """
  U8：超时释放 worker（KTD5/R8/F2）。

  - 过期订单扫描后：订单 expired + 报名 expired + confirmed_count 回落 +
    名额可重新报名。
  - 未到期 / paid / cancelled 不扫中（SQL 下推过滤，混合布置只有过期单变化）。
  - 与落账同秒竞态：mark_paid 与 :expire 并发对同一订单，恰好一方成功，
    无双重状态（CAS 行锁裁决）。
  - 空表 / 全非 pending：零动作。
  """

  use Cgc2046.DataCase, async: false

  require Ash.Query
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Payments.Order
  alias Cgc2046.Notifications.NotificationWorker
  alias Cgc2046.Payments.Workers.PaymentExpiryWorker

  @tier_id "55555555-5555-5555-5555-555555555555"

  describe "perform/1 超时释放" do
    test "过期订单：expired + 报名 expired + confirmed_count 回落 + 可重新报名", ctx do
      order = pending_order(ctx, capacity: 1)

      assert :ok = perform_job(PaymentExpiryWorker, %{})

      assert reload_order(order).status == :expired
      assert Ash.get!(Enrollment, order.enrollment_id, authorize?: false).status == :expired
      assert target_count(ctx, order) == 0

      # 名额回池：同一用户可重新报名（R8「可重新报名」）
      {:ok, _re} = re_enroll(ctx, order)
      assert target_count(ctx, order) == 1
    end

    test "U5/R13：过期 → 学员+组织者各一条 payment_expired；截止未过 re_enrollable=true", ctx do
      base = base_enrollment(ctx, 1, [])
      insert_identity(base.learner.id, :wechat, "exp-learner-" <> uniq())
      insert_identity(base.admin.id, :wechat, "exp-admin-" <> uniq())
      order = create_order(base, expire_at: hours(-1))

      assert :ok = perform_job(PaymentExpiryWorker, %{})

      assert reload_order(order).status == :expired

      expired_notifs = delivery_jobs("payment_expired")

      assert Enum.any?(expired_notifs, &(&1.args["user_id"] == base.learner.id))
      assert Enum.any?(expired_notifs, &(&1.args["user_id"] == base.admin.id))

      learner_notif = Enum.find(expired_notifs, &(&1.args["user_id"] == base.learner.id))
      assert learner_notif.args["data"]["re_enrollable"] == "true"
    end

    test "U5/R13：报名截止已过 → 学员数据不含可重新报名承诺", ctx do
      base = base_enrollment(ctx, 1, [])
      insert_identity(base.learner.id, :wechat, "exp-late-learner-" <> uniq())

      # 报名先落（deadline 未过），再把截止改到过去（布置纪律同 set_confirmed_count：
      # 裸 SQL 置位而非被测对象）
      {:ok, _} =
        Cgc2046.Repo.query(
          "UPDATE events SET registration_deadline = NOW() - INTERVAL '1 hour' WHERE id = $1",
          [Ecto.UUID.dump!(base.event.id)]
        )

      order = create_order(base, expire_at: hours(-1))

      assert :ok = perform_job(PaymentExpiryWorker, %{})

      assert [notif] =
               delivery_jobs("payment_expired")
               |> Enum.filter(&(&1.args["user_id"] == base.learner.id))

      assert notif.args["data"]["re_enrollable"] == "false"
    end

    test "review F8：nil registration_deadline 不崩溃，re_enrollable=true；已取消活动不承诺", ctx do
      base = base_enrollment(ctx, nil)
      insert_identity(base.learner.id, :wechat, "exp-nil-dl-" <> uniq())
      order = create_order(base, expire_at: hours(-1))

      # 布置：deadline 置 NULL（布置纪律同 set_confirmed_count：裸 SQL 而非被测对象）
      {:ok, _} =
        Cgc2046.Repo.query(
          "UPDATE events SET registration_deadline = NULL WHERE id = $1",
          [Ecto.UUID.dump!(base.event.id)]
        )

      assert :ok = perform_job(PaymentExpiryWorker, %{})
      assert reload_order(order).status == :expired

      notif =
        delivery_jobs("payment_expired")
        |> Enum.find(&(&1.args["user_id"] == base.learner.id))

      refute is_nil(notif)
      assert notif.args["data"]["re_enrollable"] == "true"

      # 已取消活动：re_enrollable=false（open 状态门）
      base2 = base_enrollment(ctx, nil)
      insert_identity(base2.learner.id, :wechat, "exp-cancelled-" <> uniq())
      order2 = create_order(base2, expire_at: hours(-1))

      {:ok, _} =
        Cgc2046.Repo.query(
          "UPDATE events SET status = 'cancelled' WHERE id = $1",
          [Ecto.UUID.dump!(base2.event.id)]
        )

      assert :ok = perform_job(PaymentExpiryWorker, %{})
      assert reload_order(order2).status == :expired

      notif2 =
        delivery_jobs("payment_expired")
        |> Enum.find(&(&1.args["user_id"] == base2.learner.id))

      assert notif2.args["data"]["re_enrollable"] == "false"
    end

    test "SQL 下推：未到期 / paid / cancelled 不扫中，只有过期单变化", ctx do
      expired = pending_order(ctx, expire_at: hours(-1))
      not_due = pending_order(ctx, expire_at: hours(1))
      paid = paid_order(ctx)
      cancelled = pending_order(ctx, expire_at: hours(-1))
      {:ok, _} = cancel_order(cancelled)

      assert :ok = perform_job(PaymentExpiryWorker, %{})

      assert reload_order(expired).status == :expired
      assert reload_order(not_due).status == :pending
      assert reload_order(paid).status == :paid
      assert reload_order(cancelled).status == :cancelled
    end

    test "与落账同秒竞态：落账链与 expire 并发恰一方成功，无双重状态", ctx do
      order = pending_order(ctx)

      results =
        [
          Task.async(fn ->
            # 落账链压缩形态（worker 内序）：订单 mark_paid → 报名 settle_paid
            with {:ok, paid} <-
                   reload_order(order)
                   |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "race-txn"})
                   |> Ash.update(tenant: order.workspace_id, authorize?: false),
                 {:ok, _} <-
                   Ash.get!(Enrollment, paid.enrollment_id, authorize?: false)
                   |> Ash.Changeset.for_update(:settle_paid, %{})
                   |> Ash.update(tenant: paid.workspace_id, authorize?: false) do
              {:ok, :settled}
            end
          end),
          Task.async(fn ->
            # 超时链：订单+报名+名额一体（prepare_expire 联动）
            reload_order(order)
            |> Ash.Changeset.for_update(:expire, %{})
            |> Ash.update(tenant: order.workspace_id, authorize?: false)
          end)
        ]
        |> Task.await_many(15_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, _}, &1)) == 1

      # 终态二选一且与报名侧联动一致，无双重状态（paid→confirmed / expired→expired）
      final = reload_order(order)
      enrollment = Ash.get!(Enrollment, order.enrollment_id, authorize?: false)

      case final.status do
        :paid -> assert enrollment.status == :confirmed
        :expired -> assert enrollment.status == :expired
        other -> flunk("unexpected terminal status #{other}")
      end
    end

    test "空表：零动作", _ctx do
      assert :ok = perform_job(PaymentExpiryWorker, %{})
    end
  end

  describe "perform/1 孤儿 payment_pending（无订单占座）" do
    test "超窗无订单 → 释放，名额回池，可重新报名", ctx do
      base = base_enrollment(ctx, 1)
      set_inserted_at(base.enrollment, hours(-3))

      assert :ok = perform_job(PaymentExpiryWorker, %{})

      enrollment = Ash.get!(Enrollment, base.enrollment.id, authorize?: false)
      assert enrollment.status == :expired
      refute is_nil(enrollment.expired_at)
      assert target_count_for(base) == 0

      {:ok, _re} = re_enroll(ctx, %{enrollment_id: base.enrollment.id, workspace_id: base.workspace.id})
      assert target_count_for(base) == 1
    end

    test "未超窗 → 不动", ctx do
      base = base_enrollment(ctx, 1)
      set_inserted_at(base.enrollment, hours(-1))

      assert :ok = perform_job(PaymentExpiryWorker, %{})

      enrollment = Ash.get!(Enrollment, base.enrollment.id, authorize?: false)
      assert enrollment.status == :payment_pending
      assert target_count_for(base) == 1
    end

    test "request 策略按 approved_at 计：approved_at 未超窗 → 不动，超窗 → 释放", ctx do
      base = base_enrollment(ctx, 1)
      set_inserted_at(base.enrollment, days(-3))
      set_approved_at(base.enrollment, minutes(-30))

      assert :ok = perform_job(PaymentExpiryWorker, %{})

      assert Ash.get!(Enrollment, base.enrollment.id, authorize?: false).status ==
               :payment_pending

      set_approved_at(base.enrollment, hours(-3))

      assert :ok = perform_job(PaymentExpiryWorker, %{})

      assert Ash.get!(Enrollment, base.enrollment.id, authorize?: false).status == :expired
    end

    test "有活跃订单 → 不动（交给订单过期链）", ctx do
      base = base_enrollment(ctx, 1)
      set_inserted_at(base.enrollment, hours(-3))
      order = create_order(base, expire_at: hours(1))

      assert :ok = perform_job(PaymentExpiryWorker, %{})

      assert Ash.get!(Enrollment, base.enrollment.id, authorize?: false).status ==
               :payment_pending

      assert reload_order(order).status == :pending
    end

    test "paid 订单但报名尚未落账 → 不动（落账 worker 会把它转 confirmed）", ctx do
      base = base_enrollment(ctx, 1)
      set_inserted_at(base.enrollment, hours(-3))
      order = create_order(base, expire_at: hours(1))

      {:ok, paid} =
        order
        |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "orphan-paid-txn"})
        |> Ash.update(tenant: order.workspace_id, authorize?: false)

      assert :ok = perform_job(PaymentExpiryWorker, %{})

      assert Ash.get!(Enrollment, base.enrollment.id, authorize?: false).status ==
               :payment_pending

      assert reload_order(paid).status == :paid
    end

    test "已确认 / 已取消的报名不受影响，只有孤儿那条变化", ctx do
      orphan = base_enrollment(ctx, 3)
      set_inserted_at(orphan.enrollment, hours(-3))

      confirmed_base = base_enrollment(ctx, 3)
      order = create_order(confirmed_base, expire_at: hours(1))

      {:ok, paid} =
        order
        |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "confirmed-txn"})
        |> Ash.update(tenant: order.workspace_id, authorize?: false)

      {:ok, _} =
        Ash.get!(Enrollment, confirmed_base.enrollment.id, authorize?: false)
        |> Ash.Changeset.for_update(:settle_paid, %{})
        |> Ash.update(tenant: paid.workspace_id, authorize?: false)

      cancelled_base = base_enrollment(ctx, 3)
      set_inserted_at(cancelled_base.enrollment, hours(-3))

      {:ok, _} =
        Ash.get!(Enrollment, cancelled_base.enrollment.id, authorize?: false)
        |> Ash.Changeset.for_update(:cancel, %{})
        |> Ash.update(tenant: cancelled_base.workspace.id, actor: cancelled_base.learner)

      assert :ok = perform_job(PaymentExpiryWorker, %{})

      assert Ash.get!(Enrollment, orphan.enrollment.id, authorize?: false).status == :expired

      assert Ash.get!(Enrollment, confirmed_base.enrollment.id, authorize?: false).status ==
               :confirmed

      assert Ash.get!(Enrollment, cancelled_base.enrollment.id, authorize?: false).status ==
               :cancelled
    end

    # DataCase async: false → Sandbox shared 模式：整个测试只有一条被 owner 检出
    # 的物理连接，Task 内 Repo.transaction 持有它阻塞在 receive 时，主进程的
    # perform_job 查询无连接可用只能排队超时——不是在验证锁语义，而是连接池
    # 饥饿（实测 DBConnection.ConnectionError: could not checkout the connection
    # owned by ...，非死锁/非断言失败）。按计划 Step 4 说明：这种编排在本仓
    # DataCase sandbox 下不可行，跳过而非删除 Step 3 的锁，也不改用其他编排
    # （改用其他编排前计划要求先 STOP）。
    @tag :skip
    test "并发：孤儿报名下单事务未提交时不被误释放", ctx do
      base = base_enrollment(ctx, 1)
      set_inserted_at(base.enrollment, hours(-3))

      test_pid = self()

      task =
        Task.async(fn ->
          Cgc2046.Repo.transaction(fn ->
            {:ok, _locked} = Enrollment.lock_for_order(base.enrollment.id)

            {:ok, order} =
              Order
              |> Ash.Changeset.for_create(:create, %{
                enrollment_id: base.enrollment.id,
                provider: :wechat_native,
                out_trade_no: "oto-" <> Ecto.UUID.generate(),
                amount_cents: 19_900,
                tier_snapshot: %{
                  "id" => @tier_id,
                  "name" => "标准",
                  "amount_cents" => 19_900
                },
                expire_at: hours(1)
              })
              |> Ash.create(tenant: base.workspace.id, authorize?: false)

            send(test_pid, {:order_created, order.id})

            receive do
              :proceed -> :ok
            after
              5_000 -> :timeout
            end

            order
          end)
        end)

      order_id =
        receive do
          {:order_created, id} -> id
        after
          5_000 -> flunk("order-create side did not signal in time")
        end

      assert :ok = perform_job(PaymentExpiryWorker, %{})

      send(task.pid, :proceed)
      {:ok, order} = Task.await(task, 5_000)
      assert order.id == order_id

      assert reload_order(order).status == :pending
      assert Ash.get!(Enrollment, base.enrollment.id, authorize?: false).status ==
               :payment_pending
    end
  end

  # ── 布置 ──

  defp hours(n), do: DateTime.add(DateTime.utc_now(), n, :hour)
  defp minutes(n), do: DateTime.add(DateTime.utc_now(), n, :minute)
  defp days(n), do: DateTime.add(DateTime.utc_now(), n, :day)

  # 布置纪律同既有 registration_deadline 写法（:60-66）：裸 SQL 改列而非被测对象。
  defp set_inserted_at(enrollment, at) do
    Cgc2046.Repo.query!(
      "UPDATE enrollments SET inserted_at = $1 WHERE id = $2",
      [DateTime.to_naive(at), Ecto.UUID.dump!(enrollment.id)]
    )
  end

  defp set_approved_at(enrollment, at) do
    Cgc2046.Repo.query!(
      "UPDATE enrollments SET approved_at = $1 WHERE id = $2",
      [DateTime.to_naive(at), Ecto.UUID.dump!(enrollment.id)]
    )
  end

  defp target_count_for(base) do
    {:ok, ledger} = Cgc2046.Admission.CapacityLedger.fetch_by_offering(:event, base.event.id)
    ledger.occupancy
  end

  defp pending_order(ctx, overrides \\ []) do
    ctx
    |> base_enrollment(Keyword.get(overrides, :capacity))
    |> create_order(expire_at: Keyword.get(overrides, :expire_at, hours(-1)))
  end

  defp paid_order(ctx) do
    order = pending_order(ctx, expire_at: hours(1))

    {:ok, paid} =
      order
      |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "paid-txn"})
      |> Ash.update(tenant: order.workspace_id, authorize?: false)

    {:ok, _} =
      Ash.get!(Enrollment, order.enrollment_id, authorize?: false)
      |> Ash.Changeset.for_update(:settle_paid, %{})
      |> Ash.update(tenant: order.workspace_id, authorize?: false)

    paid
  end

  # #847 批 2：资金类已迁耐久路径，行为面 = Delivery 行（伪 job 投影保持断言形状）
  defp delivery_jobs(template_key) do
    Cgc2046.Notifications.NotificationDelivery
    |> Ash.Query.filter(template_key == ^template_key)
    |> Ash.read!(authorize?: false)
    |> Enum.map(
      &%{
        args: %{
          "template_key" => &1.template_key,
          "user_id" => &1.user_id,
          "data" => &1.data
        }
      }
    )
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

  defp cancel_order(order) do
    order
    |> Ash.Changeset.for_update(:cancel, %{cancel_reason: "test_setup"})
    |> Ash.update(tenant: order.workspace_id, authorize?: false)
  end

  defp base_enrollment(_ctx, capacity, overrides \\ []) do
    admin = Fixtures.platform_admin("expiry-admin-" <> uniq())
    workspace = Fixtures.create_workspace(admin)

    deadline =
      if overrides[:deadline_passed],
        do: DateTime.add(DateTime.utc_now(), -1, :hour),
        else: DateTime.add(DateTime.utc_now(), 7, :day)

    event =
      EventFixtures.create_event(workspace, admin, %{
        capacity: capacity,
        pricing_enabled: true,
        registration_deadline: deadline,
        price_tiers: [%{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}]
      })

    learner = Fixtures.register_user("expiry-learner-" <> uniq())

    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{
        event_id: event.id,
        user_id: learner.id,
        tier_id: @tier_id
      })
      |> Ash.create(tenant: workspace.id, actor: learner)

    %{workspace: workspace, event: event, admin: admin, learner: learner, enrollment: enrollment}
  end

  defp create_order(base, overrides) do
    {:ok, order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        enrollment_id: base.enrollment.id,
        provider: :wechat_native,
        out_trade_no: "oto-" <> Ecto.UUID.generate(),
        amount_cents: 19_900,
        tier_snapshot: %{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900},
        expire_at: Keyword.get(overrides, :expire_at, hours(-1))
      })
      |> Ash.create(tenant: base.workspace.id, authorize?: false)

    order
  end

  defp re_enroll(_ctx, old_order) do
    base = base_of(old_order)

    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{
        event_id: base.event_id,
        user_id: base.user_id,
        tier_id: @tier_id
      })
      |> Ash.create(tenant: base.workspace_id, actor: base.actor)

    {:ok, enrollment}
  end

  defp base_of(order) do
    enrollment = Ash.get!(Enrollment, order.enrollment_id, authorize?: false)

    %{
      event_id: enrollment.event_id,
      user_id: enrollment.user_id,
      workspace_id: order.workspace_id,
      actor: %{id: enrollment.user_id}
    }
  end

  # ADR-0009 PR⑤ U6 口径平移：占位计数权威 = 名额账本 occupancy（原 events.confirmed_count）
  defp target_count(_ctx, order) do
    enrollment = Ash.get!(Enrollment, order.enrollment_id, authorize?: false)

    {:ok, ledger} =
      Cgc2046.Admission.CapacityLedger.fetch_by_offering(:event, enrollment.event_id)

    ledger.occupancy
  end

  defp reload_order(order) do
    Ash.get!(Order, order.id, tenant: order.workspace_id, authorize?: false)
  end

  defp uniq, do: String.slice(Ecto.UUID.generate(), 0, 8)
end
