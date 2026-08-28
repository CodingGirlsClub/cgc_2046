defmodule Cgc2046.Workers.PaymentExpiryWorkerTest do
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
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Payments.Order
  alias Cgc2046.Workers.{NotificationWorker, PaymentExpiryWorker}

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

      expired_notifs =
        all_enqueued(worker: NotificationWorker)
        |> Enum.filter(&(&1.args["template_key"] == "payment_expired"))

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
               all_enqueued(worker: NotificationWorker)
               |> Enum.filter(&(&1.args["template_key"] == "payment_expired"))
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
        all_enqueued(worker: NotificationWorker)
        |> Enum.find(
          &(&1.args["template_key"] == "payment_expired" and &1.args["user_id"] == base.learner.id)
        )

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
        all_enqueued(worker: NotificationWorker)
        |> Enum.find(
          &(&1.args["template_key"] == "payment_expired" and
              &1.args["user_id"] == base2.learner.id)
        )

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

  # ── 布置 ──

  defp hours(n), do: DateTime.add(DateTime.utc_now(), n, :hour)

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
