defmodule Cgc2046.Payments.Workers.PaymentWorkersFailclosedGuardTest do
  @moduledoc """
  015：payments worker 错误路径 fail-open 收口的故障注入测试（串行文件）。

  覆盖四个「错误绝不吞」守卫，注入手段均为**沙箱事务内 DDL**（事务性，测试
  结束自动回滚）。DDL 注入需要表级 ACCESS EXCLUSIVE 锁，故本文件 `async: false`
  串行执行——不要把这类测试迁进 async: true 文件（与并行测试在 payments_orders
  等热表上互等甚至死锁，复审 F2）：

  - `PaymentRefundWorker.waived?/1` 读 AdminActionLog 失败 → `{:error, reason}`
    上抛而非折叠为 false（false 会把免缴学员的已确认报名错误取消，不可逆）；
  - `PaymentSettlementWorker` 落账 DB 瞬断（mark_paid 失败且 reload 仍 pending）
    → `{:error, :order_still_pending}` 上抛重试，绝不 mark_processed 永久丢单；
  - `PaymentExpiryWorker` 硬失败（DB 类错误）→ `{:error, :expire_hard_failure}`
    整拍上抛走 Oban 重试（毒记录不再每分钟静默重试到永远）；
  - `PaymentExpiryWorker` CAS 未命中（BEFORE UPDATE RETURN NULL 确定性模拟
    num_rows=0）→ 预期竞态 `:skip`，整拍仍 `:ok`。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Payments.Order
  alias Cgc2046.Payments.Providers.Fake
  alias Cgc2046.Payments.WebhookEvent
  alias Cgc2046.Payments.Workers.PaymentExpiryWorker
  alias Cgc2046.Payments.Workers.PaymentRefundWorker
  alias Cgc2046.Payments.Workers.PaymentSettlementWorker

  require Ash.Query

  @tier_id "77777777-7777-7777-7777-777777777777"
  @tier %{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}

  describe "PaymentRefundWorker waived? 读失败守卫" do
    test "读失败 → {:error} 不取消免缴报名；恢复后重入按免缴语义保留 confirmed" do
      %{enrollment: enrollment, order: order} = paid_order_setup()

      # 免缴审计行（waived? 的判定事实源；真实写入在 waive_payment action，
      # 此处等效布置——审计行存在 ⇔ 免缴先落，KTD4）
      {:ok, _} =
        Cgc2046.Repo.query(
          "INSERT INTO admin_action_logs " <>
            "(id, action, target_type, target_id, result, metadata, inserted_at) " <>
            "VALUES (gen_random_uuid(), 'waive_payment', 'enrollment', $1, 'success', '{}'::jsonb, NOW())",
          [Cgc2046.Repo.uuid!(enrollment.id)]
        )

      # 订单推到 refunded（报名收尾窗口：confirmed 未处理——F-B 同款布置）
      to_refunded(order)

      # 注入：waived? 的读失败（改名表；沙箱事务内 DDL，测试结束自动回滚）
      Cgc2046.Repo.query!("ALTER TABLE admin_action_logs RENAME TO admin_action_logs_blocked")

      assert {:error, _read_failure} =
               perform_job(PaymentRefundWorker, %{"order_id" => order.id})

      # 守卫生效：读失败绝不折叠为 false——免缴报名未被错误取消
      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :confirmed

      # 解除 → 重试经 :refunded 状态门收敛：免缴语义本体 = 钱退、报名保持 confirmed
      Cgc2046.Repo.query!("ALTER TABLE admin_action_logs_blocked RENAME TO admin_action_logs")

      assert :ok = perform_job(PaymentRefundWorker, %{"order_id" => order.id})

      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :confirmed
      assert reload_order(order).status == :refunded
    end
  end

  describe "PaymentSettlementWorker 落账 DB 瞬断守卫" do
    test "mark_paid 失败且订单仍 pending → {:error, :order_still_pending}，绝不 mark_processed" do
      # pending 单：落账链尚未开始（paid_order_setup 的订单已是 paid，不适用）
      %{order: order} = base_setup()
      stub_channel_paid(order)

      # 注入 mark_paid 的 CAS UPDATE 失败（DB 类错误形状）：pending→paid 被
      # 数据库层拒绝。此时渠道查单已确认有款且金额相符——旧实现会走 `other`
      # 分支 mark_processed 永久丢单（已收款、不落账、不退款、不重试）。
      inject_trigger("block_mark_paid", "WHEN (OLD.status = 'pending' AND NEW.status = 'paid')",
        raise?: true
      )

      assert {:error, :order_still_pending} = perform_settlement(order)

      # 事件未被消费（Oban 会重试），订单仍 pending，未误触自动退款
      assert event_for(order).status != :processed

      refute_enqueued(worker: PaymentRefundWorker)

      # 解除注入 → Oban 重试 → 完整落账收敛
      drop_trigger("block_mark_paid")

      assert :ok = perform_settlement(order)
      assert reload_order(order).status == :paid
      assert Ash.get!(Enrollment, order.enrollment_id, authorize?: false).status == :confirmed
    end
  end

  describe "PaymentExpiryWorker 错误二分类" do
    test "DB 类硬失败 → {:error, :expire_hard_failure} 整拍重试；解除后收敛 expired" do
      %{order: order} = expired_order_setup()

      # 注入：订单 CAS（pending→expired）被数据库层拒绝 → 非 order_already_processed
      # 的 BusinessError → 硬失败。旧实现折叠为 :skip，毒记录每分钟静默重试到永远。
      inject_trigger("block_expire", "WHEN (OLD.status = 'pending' AND NEW.status = 'expired')",
        raise?: true
      )

      assert {:error, :expire_hard_failure} = perform_job(PaymentExpiryWorker, %{})

      # 订单仍 pending 占位，等重试收敛
      assert reload_order(order).status == :pending

      drop_trigger("block_expire")

      assert :ok = perform_job(PaymentExpiryWorker, %{})
      assert reload_order(order).status == :expired
    end

    test "CAS 未命中（num_rows=0 确定性模拟）→ 预期竞态 :skip，整拍 :ok" do
      %{order: order} = expired_order_setup()

      # BEFORE UPDATE RETURN NULL 静默吞掉 UPDATE：claim/4 得 num_rows=0 →
      # BusinessError code "order_already_processed" → 预期竞态分支。
      inject_trigger("swallow_expire", "WHEN (OLD.status = 'pending' AND NEW.status = 'expired')",
        raise?: false
      )

      assert :ok = perform_job(PaymentExpiryWorker, %{})

      # :skip 不阻塞整拍；订单保持 pending（吞掉的 UPDATE 未生效），下拍再扫
      assert reload_order(order).status == :pending

      drop_trigger("swallow_expire")

      assert :ok = perform_job(PaymentExpiryWorker, %{})
      assert reload_order(order).status == :expired
    end
  end

  # ── 布置 ──

  # paid 落账完成态：order=paid + enrollment=confirmed（免缴/落账守卫共用的
  # 占位确认态布置）
  defp paid_order_setup do
    %{workspace: workspace, enrollment: enrollment, order: order} = base_setup()

    {:ok, _} =
      order
      |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "guard-txn"})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    {:ok, _} =
      Ash.get!(Enrollment, enrollment.id, authorize?: false)
      |> Ash.Changeset.for_update(:settle_paid, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    %{
      workspace: workspace,
      enrollment: enrollment,
      order: reload_order(order)
    }
  end

  # 过期扫描命中态：pending 订单且 expire_at 已过点。
  # （唯一活跃单索引：每报名至多一个非终态订单——先 cancel 布置单（终态），
  # 再建第二笔带过期时刻的 pending 单）
  defp expired_order_setup do
    %{workspace: workspace, enrollment: enrollment, order: order} = base_setup()

    {:ok, _} =
      order
      |> Ash.Changeset.for_update(:cancel, %{cancel_reason: "guard_recreate"})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    {:ok, order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        enrollment_id: enrollment.id,
        provider: :wechat_native,
        out_trade_no: "oto-" <> Ecto.UUID.generate(),
        amount_cents: 19_900,
        tier_snapshot: @tier,
        expire_at: DateTime.add(DateTime.utc_now(), -1, :hour)
      })
      |> Ash.create(tenant: workspace.id, authorize?: false)

    %{workspace: workspace, enrollment: enrollment, order: order}
  end

  defp base_setup do
    admin = Fixtures.platform_admin("failclosed-guard-admin-" <> uniq())
    workspace = Fixtures.create_workspace(admin)

    event =
      EventFixtures.create_event(workspace, admin, %{
        pricing_enabled: true,
        price_tiers: [@tier]
      })

    learner = Fixtures.register_user("failclosed-guard-learner-" <> uniq())

    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{
        event_id: event.id,
        user_id: learner.id,
        tier_id: @tier_id
      })
      |> Ash.create(tenant: workspace.id, actor: learner)

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

    %{workspace: workspace, enrollment: enrollment, order: order}
  end

  defp to_refunded(order) do
    {:ok, refunding} =
      order
      |> Ash.Changeset.for_update(:start_refund, %{})
      |> Ash.update(tenant: order.workspace_id, authorize?: false)

    {:ok, _} =
      refunding
      |> Ash.Changeset.for_update(:refund_succeeded, %{})
      |> Ash.update(tenant: order.workspace_id, authorize?: false)
  end

  # 沙箱事务内注入/解除 payments_orders 行级触发器（DDL 事务性，测试结束回滚；
  # 本文件 async: false 串行——迁移到并行文件会在热表上互等，见 moduledoc F2）
  defp inject_trigger(name, when_clause, opts) do
    body =
      if Keyword.get(opts, :raise?, true) do
        "BEGIN RAISE EXCEPTION 'test injected db failure'; END;"
      else
        "BEGIN RETURN NULL; END;"
      end

    Cgc2046.Repo.query!(
      ~s{CREATE OR REPLACE FUNCTION cgc_test_#{name}() RETURNS trigger AS } <>
        ~s{$$ #{body} $$ LANGUAGE plpgsql;}
    )

    Cgc2046.Repo.query!(
      ~s{CREATE TRIGGER #{name} BEFORE UPDATE ON payments_orders FOR EACH ROW } <>
        ~s{#{when_clause} EXECUTE FUNCTION cgc_test_#{name}();}
    )
  end

  defp drop_trigger(name) do
    Cgc2046.Repo.query!("DROP TRIGGER #{name} ON payments_orders")
    Cgc2046.Repo.query!("DROP FUNCTION cgc_test_#{name}")
  end

  defp stub_channel_paid(order) do
    Fake.script!(
      fetch_transaction:
        {:ok, %{status: :paid, amount_cents: order.amount_cents, transaction_id: "txn-guard-1"}}
    )
  end

  defp perform_settlement(order) do
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

  defp event_for(order) do
    WebhookEvent
    |> Ash.Query.filter(event_id == ^("evt-" <> order.out_trade_no))
    |> Ash.read_one!(authorize?: false)
  end

  defp reload_order(order) do
    Ash.get!(Order, order.id, tenant: order.workspace_id, authorize?: false)
  end

  defp uniq, do: String.slice(Ecto.UUID.generate(), 0, 8)
end
