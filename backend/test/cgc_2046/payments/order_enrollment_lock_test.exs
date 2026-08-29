defmodule Cgc2046.Payments.OrderEnrollmentLockTest do
  # ADR-0010 批次4（⑨ 跨域行锁端口化）钉测——先写于现代码（FOR UPDATE 内联在
  # Payments.Order prepare_create_for_enrollment），SQL 原样内迁 Admission 端口
  # （Enrollment.lock_for_order/1）后本测试必须仍绿：钉的是「两事务竞争同一
  # enrollment 行的序列化语义」行为契约，不钉实现位置。
  #
  # 沙箱纪律同 enrollment_concurrency_test：自管 owner + unboxed 真实提交
  # （共享 sandbox 事务内订阅方 claim 会持 workspaces 外键 KEY SHARE 锁，
  # 清理须先 stop_owner 再删真实行）。
  use ExUnit.Case, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Payments.Order
  alias Cgc2046.Payments.Providers.Fake
  alias Cgc2046.Repo

  @paid_tier_id "33333333-3333-3333-3333-333333333333"

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    on_exit(fn ->
      try do
        Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
      catch
        :exit, {:noproc, _} -> :ok
        :exit, :noproc -> :ok
      end
    end)

    %{sandbox_owner: owner}
  end

  test "FOR UPDATE 锁内重读 status：持锁方确认后，竞争下单获锁即拒、零订单落库",
       %{sandbox_owner: owner} do
    {workspace, event, learner, enrollment} =
      unboxed(fn ->
        admin = Fixtures.platform_admin("lock-order-admin")
        workspace = Fixtures.create_workspace(admin)

        event =
          EventFixtures.create_event(workspace, admin, %{
            pricing_enabled: true,
            price_tiers: [
              %{"id" => @paid_tier_id, "name" => "早鸟", "amount_cents" => 9900}
            ]
          })

        learner = Fixtures.register_user("lock-order-learner")

        {:ok, enrollment} =
          Enrollment
          |> Ash.Changeset.for_create(:create_enrollment, %{
            event_id: event.id,
            user_id: learner.id,
            tier_id: @paid_tier_id
          })
          |> Ash.create(tenant: workspace.id, actor: learner)

        assert enrollment.status == :payment_pending
        {workspace, event, learner, enrollment}
      end)

    cleanup_on_exit(owner, workspace, event, [learner])

    # 事务编排（确定性复现 F5 竞态的「免缴先提交」臂）：
    # 1) 本测试事务先持 enrollment 行 FOR UPDATE 锁；
    # 2) 下单任务进入 load_enrollment 的 FOR UPDATE → 阻塞等锁（pg_locks 取证）；
    # 3) 持锁方把 status 改为 confirmed（模拟免缴事务）并提交释放锁；
    # 4) 下单获锁后锁内重读 status=confirmed → 拒单（not awaiting payment）。
    task =
      Task.async(fn ->
        unboxed(fn ->
          Order
          |> Ash.Changeset.for_create(:create_for_enrollment, %{
            enrollment_id: enrollment.id,
            provider: :wechat_native
          })
          |> Ash.create(tenant: workspace.id, actor: learner)
        end)
      end)

    # 持锁事务必须 unboxed（真连接真提交）——shared sandbox 下测试进程的
    # Repo.transaction 只是 owner 大事务内的 savepoint，行锁不随其释放。
    result =
      unboxed(fn ->
        Repo.transaction(fn ->
          {:ok, %{rows: [[_]]}} =
            Repo.query("SELECT id FROM enrollments WHERE id = $1 FOR UPDATE", [
              Repo.uuid!(enrollment.id)
            ])

          assert :blocked = wait_until_blocked_on_row()

          {:ok, _} =
            Repo.query("UPDATE enrollments SET status = 'confirmed' WHERE id = $1", [
              Repo.uuid!(enrollment.id)
            ])
        end)
      end)

    assert {:ok, _} = result

    assert {:error, %Ash.Error.Invalid{} = error} = Task.await(task, 15_000)
    assert Exception.message(error) =~ "not awaiting payment"

    unboxed(fn ->
      {:ok, %{rows: [[0]]}} =
        Repo.query("SELECT count(*) FROM payments_orders WHERE enrollment_id = $1", [
          Repo.uuid!(enrollment.id)
        ])
    end)
  after
    Fake.reset!()
  end

  # 下单任务阻塞于 enrollment 行锁的取证：pg_locks 出现未授予的 tuple/xact 锁
  # （FOR UPDATE 等待者的两种等待形态）。~5s 未观测到 = 竞态编排失败（测试红）。
  defp wait_until_blocked_on_row(deadline_ms \\ 5_000)

  defp wait_until_blocked_on_row(deadline_ms) when deadline_ms <= 0, do: :timeout

  defp wait_until_blocked_on_row(deadline_ms) do
    {:ok, %{rows: [[waiting]]}} =
      Repo.query(
        "SELECT count(*) FROM pg_locks WHERE NOT granted AND locktype IN ('tuple', 'transactionid')",
        []
      )

    if waiting > 0 do
      :blocked
    else
      Process.sleep(50)
      wait_until_blocked_on_row(deadline_ms - 50)
    end
  end

  defp cleanup_on_exit(owner, workspace, event, users) do
    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)

      unboxed(fn ->
        Repo.query!(
          "DELETE FROM payments_orders WHERE enrollment_id IN (SELECT id FROM enrollments WHERE event_id = $1)",
          [
            Repo.uuid!(event.id)
          ]
        )

        Repo.query!("DELETE FROM enrollments WHERE event_id = $1", [Repo.uuid!(event.id)])

        Repo.query!("DELETE FROM admission_capacity_ledgers WHERE offering_id = $1", [
          Repo.uuid!(event.id)
        ])

        Repo.query!(
          "DELETE FROM membership_roles WHERE membership_id IN (SELECT id FROM workspace_memberships WHERE workspace_id = $1)",
          [Repo.uuid!(workspace.id)]
        )

        Repo.query!("DELETE FROM workspace_memberships WHERE workspace_id = $1", [
          Repo.uuid!(workspace.id)
        ])

        Repo.query!("DELETE FROM events WHERE workspace_id = $1", [Repo.uuid!(workspace.id)])

        Repo.query!(
          "DELETE FROM admin_action_logs WHERE target_type = 'workspace' AND target_id = $1",
          [Repo.uuid!(workspace.id)]
        )

        Repo.query!("DELETE FROM workspaces WHERE id = $1", [Repo.uuid!(workspace.id)])

        Enum.each(users, fn user ->
          Repo.query!("DELETE FROM users WHERE id = $1", [Repo.uuid!(user.id)])
        end)
      end)
    end)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
