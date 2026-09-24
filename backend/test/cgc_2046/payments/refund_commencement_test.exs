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

  @tier_id "88888888-8888-8888-8888-888888888888"
  @tier %{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}

  describe "状态分派矩阵" do
    test "paid + eligible → {:ok, :started}，refundings + 恰一笔 job" do
      %{order: order} = paid_order_setup()

      assert {:ok, :started} = RefundCommencement.commence(order, eligible: [:paid])

      assert reload_order(order).status == :refunding

      assert [%{args: %{"order_id" => order_id}}] =
               all_enqueued(worker: PaymentRefundWorker)
               |> Enum.filter(&(&1.args["order_id"] == order.id))

      assert order_id == order.id
    end

    test "refund_failed + eligible → {:ok, :retried}，重入退款链" do
      %{order: order} = paid_order_setup()
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
    # R1-#3：两个 task 各自 unboxed_run 拿独立非沙箱连接（shared sandbox 下
    # 不切连接则共享同一条 pg_backend_pid，实为串行）；布置亦 unboxed 真提交，
    # worker 连接才可见；数据由 on_exit 自行清理。
    test "两进程独立连接同时 commence 同一 paid 单：恰一 :started、另一 :already_in_progress，恰一笔 job" do
      {workspace, order} =
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          %{workspace: workspace, order: order} = paid_order_setup()
          {workspace, reload_order(order)}
        end)

      on_exit(fn ->
        # unboxed 真提交的布置清理（OrderEnrollmentLockTest / attendance 并发
        # 用例同款：先释放 sandbox 事务再按子→父删）——workflow_definitions
        # 与 workspace_memberships 的 FK 无级联，必须先于 workspace 删除；
        # webhook_events 为多态事件表（无 FK），按本布置的 event_id 删
        Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.query!("DELETE FROM oban_jobs WHERE args->>'order_id' = $1", [order.id])

          Repo.query!("DELETE FROM payments_orders WHERE enrollment_id = $1", [
            Repo.uuid!(order.enrollment_id)
          ])

          Repo.query!("DELETE FROM enrollments WHERE id = $1", [Repo.uuid!(order.enrollment_id)])

          Repo.query!("DELETE FROM payments_webhook_events WHERE event_id = $1", [
            "evt-" <> order.out_trade_no
          ])

          Repo.query!("DELETE FROM workflow_definitions WHERE workspace_id = $1", [
            Repo.uuid!(workspace.id)
          ])

          Repo.query!(
            "DELETE FROM membership_roles WHERE membership_id IN (SELECT id FROM workspace_memberships WHERE workspace_id = $1)",
            [Repo.uuid!(workspace.id)]
          )

          Repo.query!("DELETE FROM workspace_memberships WHERE workspace_id = $1", [
            Repo.uuid!(workspace.id)
          ])

          Repo.query!("DELETE FROM events WHERE workspace_id = $1", [Repo.uuid!(workspace.id)])
          Repo.query!("DELETE FROM workspaces WHERE id = $1", [Repo.uuid!(workspace.id)])
        end)
      end)

      test_pid = self()

      tasks =
        Enum.map(1..2, fn _ ->
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
              {:ok, %{rows: [[backend_pid]]}} = Repo.query("SELECT pg_backend_pid()", [])

              send(test_pid, {:backend_pid, backend_pid})
              RefundCommencement.commence(order, eligible: [:paid])
            end)
          end)
        end)

      results = Enum.map(tasks, &Task.await(&1, 15_000))

      pids =
        for _ <- 1..2 do
          receive do
            {:backend_pid, pid} -> pid
          after
            5_000 -> flunk("task 未上报 pg_backend_pid（编排失败）")
          end
        end

      # 独立连接：两 task 的 pg_backend_pid 必须不同（否则只是串行重放）
      assert length(Enum.uniq(pids)) == 2

      # 恰一 :started、恰一 :already_in_progress（不依赖原子排序的脆弱比较）
      assert Enum.count(results, &(&1 == {:ok, :started})) == 1
      assert Enum.count(results, &(&1 == {:ok, :already_in_progress})) == 1

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

  defp reload_order(order),
    do: Ash.get!(Order, order.id, tenant: order.workspace_id, authorize?: false)

  defp uniq, do: String.slice(Ecto.UUID.generate(), 0, 8)
end
