defmodule Cgc2046.Payments.OrderTest do
  @moduledoc """
  支付闭环 U1：Order 状态机骨架 + 库级不变量（R11 唯一活跃订单部分索引 /
  R21 WebhookEvent 幂等去重）。

  全部动作以 authorize?: false 走内部路径（worker/域服务语义）；面向用户的
  policy 随 U5/U9 暴露时细化。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Payments.{Order, WebhookEvent}

  describe "状态机：合法迁移" do
    test "mark_paid：pending → paid，落 transaction_id" do
      order = order_fixture()

      assert {:ok, paid} = transition(order, :mark_paid, %{transaction_id: "wx-txn-001"})
      assert paid.status == :paid
      assert paid.transaction_id == "wx-txn-001"
    end

    test "cancel：pending → cancelled，落 cancel_reason" do
      order = order_fixture()

      assert {:ok, cancelled} =
               transition(order, :cancel, %{cancel_reason: "用户切换支付方式"})

      assert cancelled.status == :cancelled
      assert cancelled.cancel_reason == "用户切换支付方式"
    end

    test "expire：pending → expired" do
      order = order_fixture()

      assert {:ok, expired} = transition(order, :expire)
      assert expired.status == :expired
    end

    test "start_refund + refund_succeeded：paid → refunding → refunded，落 refunded_at" do
      order = paid_order()

      assert {:ok, refunding} = transition(order, :start_refund)
      assert refunding.status == :refunding

      assert {:ok, refunded} = transition(refunding, :refund_succeeded)
      assert refunded.status == :refunded
      refute is_nil(refunded.refunded_at)
    end

    test "迟到支付自动退款路径（ADR-0007）：expired → refunding → refunded" do
      order = expired_order()

      assert {:ok, refunding} = transition(order, :start_refund)
      assert refunding.status == :refunding

      assert {:ok, refunded} = transition(refunding, :refund_succeeded)
      assert refunded.status == :refunded
      refute is_nil(refunded.refunded_at)
    end

    test "迟到支付自动退款路径（e2e #1）：cancelled → refunding → refunded" do
      # 免缴/报名取消作废的单，本地作废不关渠道单——QR 仍可被支付，
      # 迟到收款必须能进退款链（AE2 语义）
      {:ok, cancelled} = transition(order_fixture(), :cancel, %{cancel_reason: "waived"})

      assert {:ok, refunding} = transition(cancelled, :start_refund)
      assert refunding.status == :refunding

      assert {:ok, refunded} = transition(refunding, :refund_succeeded)
      assert refunded.status == :refunded
    end

    test "退款失败重试环：refunding → refund_failed →（retry_refund）refunding" do
      order = refund_failed_order()

      assert {:ok, retrying} = transition(order, :retry_refund)
      assert retrying.status == :refunding

      assert {:ok, refunded} = transition(retrying, :refund_succeeded)
      assert refunded.status == :refunded
    end
  end

  describe "状态机：非法迁移（DB CAS 拒绝，状态不变）" do
    test "pending → refunded（refund_succeeded 直跳）拒绝" do
      order = order_fixture()

      assert {:error, error} = transition(order, :refund_succeeded)
      assert Exception.message(error) =~ "already been processed"
      assert reload(order).status == :pending
    end

    test "paid → cancelled 拒绝（已支付必须走退款）" do
      order = paid_order()

      assert {:error, error} = transition(order, :cancel, %{cancel_reason: "batch void"})
      assert Exception.message(error) =~ "already been processed"
      assert reload(order).status == :paid
    end

    test "refund_failed → refunded（refund_succeeded 直跳）拒绝" do
      order = refund_failed_order()

      assert {:error, _} = transition(order, :refund_succeeded)
      assert reload(order).status == :refund_failed
    end

    test "expired → cancelled 拒绝（过期单只可进退款或另建新单）" do
      order = expired_order()

      assert {:error, _} = transition(order, :cancel, %{cancel_reason: "batch void"})
      assert reload(order).status == :expired
    end

    test "refunded 终态拒绝一切后续动作" do
      refunded = refunded_order()

      assert {:error, _} = transition(refunded, :mark_paid, %{transaction_id: "wx-txn-again"})
      assert {:error, _} = transition(refunded, :cancel, %{cancel_reason: "again"})
      assert {:error, _} = transition(refunded, :expire)
      assert {:error, _} = transition(refunded, :start_refund)
      assert {:error, _} = transition(refunded, :refund_succeeded)
      assert {:error, _} = transition(refunded, :retry_refund)

      assert reload(refunded).status == :refunded
    end

    test "cancelled 终态拒绝支付/过期动作（start_refund 除外——迟到收款退款路径）" do
      {:ok, cancelled} = transition(order_fixture(), :cancel, %{cancel_reason: "provider switch"})

      assert {:error, _} = transition(cancelled, :mark_paid, %{transaction_id: "wx-txn-again"})
      assert {:error, _} = transition(cancelled, :expire)

      assert reload(cancelled).status == :cancelled
    end
  end

  describe "R11：同一 enrollment 至多一笔非终态订单（部分唯一索引）" do
    test "并存两笔 pending 被拒绝，首笔不受影响" do
      enrollment = enrollment_fixture()
      assert {:ok, _first} = create_order(enrollment)

      assert {:error, error} = create_order(enrollment)
      assert unique_violation?(error, :enrollment_id)
      assert order_count(enrollment.id) == 1
    end

    test "cancelled 终态放行新订单（部分索引边界：索引只锁非终态窗口）" do
      enrollment = enrollment_fixture()
      {:ok, first} = create_order(enrollment)
      assert {:ok, _cancelled} = transition(first, :cancel, %{cancel_reason: "provider switch"})

      assert {:ok, second} = create_order(enrollment)
      assert second.status == :pending
      assert order_count(enrollment.id) == 2
    end

    test "expired 单进入 refunding 与既有新 pending 互斥（索引同时守卫 CAS 迁移路径）" do
      enrollment = enrollment_fixture()
      {:ok, old} = create_order(enrollment)
      assert {:ok, expired} = transition(old, :expire)

      # expired 不在索引窗口内 → 允许另建新单
      assert {:ok, _fresh} = create_order(enrollment)

      # 旧单此时进退款会让同一 enrollment 出现两笔非终态 → 唯一索引拒绝
      assert {:error, _} = transition(expired, :start_refund)
      assert reload(expired).status == :expired
    end
  end

  describe "#405：create_for_enrollment 幂等下单（重进支付页废旧开新）" do
    test "重复下单不再撞单：旧 pending 置 cancelled(reenter_refresh)、新单携新凭据" do
      {enrollment, learner} = payment_pending_enrollment("idem-reenter")

      assert {:ok, first} = checkout(enrollment, learner)
      assert {:ok, second} = checkout(enrollment, learner)

      # 废旧开新：新订单新 id 新单号；旧单 cancelled 留审计痕，终态不再占索引
      assert second.id != first.id
      assert second.out_trade_no != first.out_trade_no
      assert reload(first).status == :cancelled
      assert reload(first).cancel_reason == "reenter_refresh"
      assert order_count(enrollment.id) == 2

      # 凭据随每次下单重出且对应当次新单号（Fake 回显 out_trade_no）
      second_no = second.out_trade_no
      assert %{"out_trade_no" => ^second_no} = second.__metadata__[:credential]
    end

    test "旧单已 cancelled 终态后下单开新单（与既有 R11 行为一致）" do
      {enrollment, learner} = payment_pending_enrollment("idem-after-cancel")

      assert {:ok, first} = checkout(enrollment, learner)
      assert {:ok, _cancelled} = transition(first, :cancel, %{cancel_reason: "user_cancelled"})

      assert {:ok, second} = checkout(enrollment, learner)
      assert second.id != first.id
      assert order_count(enrollment.id) == 2
    end
  end

  describe "R21：WebhookEvent (provider, event_id) 幂等去重" do
    test "重复 (provider, event_id) 插入被拒；不同 provider 同 event_id 可并存" do
      assert {:ok, _} = create_webhook_event(:wechat, "evt-dup-1")

      assert {:error, error} = create_webhook_event(:wechat, "evt-dup-1")
      assert unique_violation?(error)

      assert {:ok, _} = create_webhook_event(:alipay, "evt-dup-1")
      assert webhook_event_count() == 2
    end
  end

  # ── 布置与断言帮手 ─────────────────────────────────────────────────────────

  defp enrollment_fixture do
    admin = Fixtures.platform_admin("payments-admin")
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin)
    learner = Fixtures.register_user("payments-learner")

    {:ok, enrollment} = create_enrollment(event, learner)
    enrollment
  end

  defp create_enrollment(event, user) do
    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, %{event_id: event.id, user_id: user.id})
    |> Ash.create(tenant: event.workspace_id, actor: user)
  end

  # #405 幂等测试布置：付费活动 + 档位 → 报名落 payment_pending；checkout 走
  # create_for_enrollment 全链路（本人 actor + Fake 渠道）。
  @idempotent_tier_id "44444444-4444-4444-4444-444444444444"

  defp payment_pending_enrollment(tag) do
    admin = Fixtures.platform_admin("payments-idem-admin-#{tag}")
    workspace = Fixtures.create_workspace(admin)

    event =
      EventFixtures.create_event(workspace, admin, %{
        pricing_enabled: true,
        price_tiers: [
          %{"id" => @idempotent_tier_id, "name" => "早鸟", "amount_cents" => 9900}
        ]
      })

    learner = Fixtures.register_user("payments-idem-learner-#{tag}")

    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{
        event_id: event.id,
        user_id: learner.id,
        tier_id: @idempotent_tier_id
      })
      |> Ash.create(tenant: workspace.id, actor: learner)

    assert enrollment.status == :payment_pending
    {enrollment, learner}
  end

  # native 渠道无 openid 前置校验（jsapi 需真实微信 openid，测试用户没有）
  defp checkout(enrollment, actor) do
    Order
    |> Ash.Changeset.for_create(:create_for_enrollment, %{
      enrollment_id: enrollment.id,
      provider: :wechat_native
    })
    |> Ash.create(tenant: enrollment.workspace_id, actor: actor)
  end

  defp order_fixture do
    {:ok, order} = enrollment_fixture() |> create_order()
    order
  end

  defp create_order(enrollment, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          enrollment_id: enrollment.id,
          provider: :wechat_jsapi,
          out_trade_no: "CGC" <> String.replace(Ecto.UUID.generate(), "-", ""),
          amount_cents: 19_900,
          expire_at: DateTime.add(DateTime.utc_now(), 2, :hour)
        },
        attrs
      )

    Order
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(tenant: enrollment.workspace_id, authorize?: false)
  end

  defp paid_order do
    transition!(order_fixture(), :mark_paid, %{transaction_id: "wx-txn-fixture"})
  end

  defp expired_order, do: transition!(order_fixture(), :expire)

  defp refund_failed_order do
    order_fixture()
    |> transition!(:mark_paid, %{transaction_id: "wx-txn-fixture"})
    |> transition!(:start_refund)
    |> transition!(:mark_refund_failed)
  end

  defp refunded_order do
    order_fixture()
    |> transition!(:mark_paid, %{transaction_id: "wx-txn-fixture"})
    |> transition!(:start_refund)
    |> transition!(:refund_succeeded)
  end

  defp transition(order, action, args \\ %{}) do
    order
    |> Ash.Changeset.for_update(action, args)
    |> Ash.update(tenant: order.workspace_id, authorize?: false)
  end

  defp transition!(order, action, args \\ %{}) do
    {:ok, updated} = transition(order, action, args)
    updated
  end

  defp create_webhook_event(provider, event_id) do
    WebhookEvent
    |> Ash.Changeset.for_create(:create, %{
      provider: provider,
      event_id: event_id,
      payload: %{"raw" => "callback payload"}
    })
    |> Ash.create(authorize?: false)
  end

  defp reload(order) do
    Ash.get!(Order, order.id, tenant: order.workspace_id, authorize?: false)
  end

  defp order_count(enrollment_id) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM payments_orders WHERE enrollment_id = $1", [
        Repo.uuid!(enrollment_id)
      ])

    count
  end

  defp webhook_event_count do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM payments_webhook_events", [])
    count
  end

  # ash_postgres 把 PG unique violation 映射为带 constraint_type: :unique 的
  # Ash 错误（单列 identity → InvalidAttribute{field: ...}；复合 identity 走
  # 其它形状，故 field 可选）。
  defp unique_violation?(%Ash.Error.Invalid{errors: errors}, field \\ nil) do
    Enum.any?(errors, fn
      %{field: f, private_vars: vars} when field in [nil, f] ->
        Keyword.get(vars || [], :constraint_type) == :unique

      %{private_vars: vars} when is_nil(field) ->
        Keyword.get(vars || [], :constraint_type) == :unique

      _ ->
        false
    end)
  end
end
