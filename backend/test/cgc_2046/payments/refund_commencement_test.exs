defmodule Cgc2046.Payments.RefundCommencementTest do
  @moduledoc """
  退款发起单一入口 RefundCommencement（#845 D2）。

  三面：状态分派矩阵（eligible 与封闭结果集）、CAS 竞态收敛（RETURN NULL
  确定性模拟 claim 未命中，重读重新分类）、真实并发（unboxed 双连接两进程
  同时对同一张 paid 单发起——shared sandbox 下普通进程共享一条连接，竞态
  不成立，ADR-0010 #9 纪律同 attendance 并发用例）。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Payments.Order
  alias Cgc2046.Payments.RefundCommencement
  alias Cgc2046.Payments.Workers.PaymentRefundWorker
  alias Cgc2046.Repo

  require Ash.Query

  @tier_id "88888888-8888-8888-8888-888888888888"
  @tier %{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}

  describe "状态分派矩阵" do
    test "paid + eligible → {:ok, :started}，refundings + 恰一笔 job" do
      %{workspace: workspace, order: order} = paid_order_setup()

      assert {:ok, :started} = RefundCommencement.commence(order, eligible: [:paid])

      assert reload_order(order).status == :refunding

      assert [%{args: %{"order_id" => order_id}}] =
               all_enqueued(worker: PaymentRefundWorker)
               |> Enum.filter(&(&1.args["order_id"] == order.id))

      assert order_id == order.id
    end

    test "refund_failed + eligible → {:ok, :retried}，重入退款链" do
      %{workspace: workspace, order: order} = paid_order_setup()
      set_status!(order, "refund_failed")

      assert {:ok, :retried} =
               RefundCommencement.commence(reload_order(order),
                 eligible: [:paid, :refund_failed]
               )

      assert reload_order(order).status == :refunding
    end

    test "refund_failed 不在 eligible → {:error, {:ineligible, :refund_failed}}，订单不动" do
      %{order: order} = paid_order_setup()
      set_status!(order, "refund_failed")

      assert {:error, {:ineligible, :refund_failed}} =
               RefundCommencement.commence(reload_order(order), eligible: [:paid])

      assert reload_order(order).status == :refund_failed
    end

    # 迟到支付自动退款路径（U7/D(a)）：expired / cancelled 单同走 start_refund
    test "expired + eligible → {:ok, :started}，refunding + 恰一笔 job" do
      %{order: order} = paid_order_setup()
      set_status!(order, "expired")

      assert {:ok, :started} =
               RefundCommencement.commence(reload_order(order),
                 eligible: [:paid, :expired, :cancelled]
               )

      assert reload_order(order).status == :refunding

      assert [%{}] =
               all_enqueued(worker: PaymentRefundWorker)
               |> Enum.filter(&(&1.args["order_id"] == order.id))
    end

    test "expired 不在 eligible → {:error, {:ineligible, :expired}}" do
      %{order: order} = paid_order_setup()
      set_status!(order, "expired")

      assert {:error, {:ineligible, :expired}} =
               RefundCommencement.commence(reload_order(order), eligible: [:paid])

      assert reload_order(order).status == :expired
    end

    test "refunding / refunded → {:ok, :already_in_progress}，不加新 job" do
      %{order: order} = paid_order_setup()

      {:ok, _} =
        order
        |> Ash.Changeset.for_update(:start_refund, %{})
        |> Ash.update(tenant: order.workspace_id, authorize?: false)

      assert reload_order(order).status == :refunding
      jobs_before = jobs_for(order)

      assert {:ok, :already_in_progress} =
               RefundCommencement.commence(reload_order(order), eligible: [:paid])

      assert jobs_for(order) == jobs_before

      set_status!(order, "refunded")

      assert {:ok, :already_in_progress} =
               RefundCommencement.commence(reload_order(order), eligible: [:paid])

      assert jobs_for(order) == jobs_before
    end

    test "forfeited / pending → {:error, {:ineligible, status}}" do
      %{order: order} = paid_order_setup()
      set_status!(order, "forfeited")

      assert {:error, {:ineligible, :forfeited}} =
               RefundCommencement.commence(reload_order(order), eligible: [:paid])

      set_status!(order, "pending")

      assert {:error, {:ineligible, :pending}} =
               RefundCommencement.commence(reload_order(order), eligible: [:paid])
    end
  end

  describe "CAS 竞态收敛" do
    # 「重读已收敛」分支由下方真实并发用例承载：败方 CAS 未命中后重读必见
    # refunding → {:ok, :already_in_progress}，比 trigger 注入更真实
    # （BEFORE/AFTER 双 trigger 模拟同行改写会引入 DB 层噪音，不采用）。

    test "claim 未命中且重读未收敛（仍 paid）→ {:error, reason} 透传，订单不动" do
      %{order: order} = paid_order_setup()

      Cgc2046.Repo.query!(
        ~s{CREATE OR REPLACE FUNCTION cgc_rc_reread_stuck() RETURNS trigger AS } <>
          ~s{$$ BEGIN RETURN NULL; END; $$ LANGUAGE plpgsql;}
      )

      Cgc2046.Repo.query!(
        ~s{CREATE TRIGGER rc_reread_stuck BEFORE UPDATE ON payments_orders FOR EACH ROW } <>
          ~s{WHEN (OLD.id = '#{order.id}' AND OLD.status = 'paid' AND NEW.status = 'refunding') } <>
          ~s{EXECUTE FUNCTION cgc_rc_reread_stuck();}
      )

      assert {:error,
              %Ash.Error.Invalid{
                errors: [%Cgc2046.Errors.BusinessError{code: "order_already_processed"}]
              }} = RefundCommencement.commence(order, eligible: [:paid])

      assert reload_order(order).status == :paid
      assert jobs_for(order) == []
    end
  end

  describe "真实并发（unboxed 双连接）" do
    test "两进程同时 commence 同一 paid 单：恰一 :started、另一 :already_in_progress，恰一笔 job" do
      %{workspace: workspace, order: order} = paid_order_setup()
      cleanup_on_exit(workspace)

      results =
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          tasks =
            Enum.map(1..2, fn _ ->
              Task.async(fn -> RefundCommencement.commence(order, eligible: [:paid]) end)
            end)

          Enum.map(tasks, &Task.await(&1, 15_000))
        end)

      assert Enum.sort(results) == [{:ok, :already_in_progress}, {:ok, :started}]

      assert reload_order(order).status == :refunding

      assert [%{}] =
               all_enqueued(worker: PaymentRefundWorker)
               |> Enum.filter(&(&1.args["order_id"] == order.id))
    end
  end

  # ── 布置 ──

  defp paid_order_setup do
    admin = Fixtures.platform_admin("rc-admin-" <> uniq())
    workspace = Fixtures.create_workspace(admin)

    event =
      EventFixtures.create_event(workspace, admin, %{pricing_enabled: true, price_tiers: [@tier]})

    learner = Fixtures.register_user("rc-learner-" <> uniq())

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

    {:ok, _} =
      order
      |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "txn-rc-" <> uniq()})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    {:ok, _} =
      enrollment
      |> Ash.Changeset.for_update(:settle_paid, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    %{workspace: workspace, event: event, enrollment: enrollment, order: reload_order(order)}
  end

  # 非本用例主链的状态布置（终态 / 滞留态）：同一订单行直改 status，不建第二笔
  defp set_status!(order, status) do
    Repo.query!("UPDATE payments_orders SET status = $1 WHERE id = $2", [
      status,
      Repo.uuid!(order.id)
    ])
  end

  defp jobs_for(order) do
    all_enqueued(worker: PaymentRefundWorker)
    |> Enum.filter(&(&1.args["order_id"] == order.id))
  end

  # unboxed 真提交的数据清理：审计行无 FK 挡路先删，再级联删 workspace
  defp cleanup_on_exit(workspace) do
    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DELETE FROM admin_action_logs WHERE metadata->>'event_id' IS NOT NULL", [])
        Repo.query!("DELETE FROM workspaces WHERE id = $1", [Repo.uuid!(workspace.id)])
      end)
    end)
  end

  defp reload_order(order),
    do: Ash.get!(Order, order.id, tenant: order.workspace_id, authorize?: false)

  defp uniq, do: String.slice(Ecto.UUID.generate(), 0, 8)
end
