defmodule Cgc2046.Events.AnchorFreezeConcurrencyTest do
  @moduledoc """
  #1103 其二：资金锚点冻结守卫与并发下单之间的 TOCTOU。

  窗口形状：守卫的触发条件 `has_active_deposit_orders?` 是一次普通查询，而
  「改锚点」持的是 **events** 行锁、下单路径持的是 **enrollments** 行锁——
  两条路径不在同一把锁上。于是这个交错可达：

    1. 管理员事务 T1 跑守卫，此刻尚无已提交的未终态押金单 → 判「无单」；
    2. 用户事务 T2 读到旧锚点、插入 pending 押金单、提交；
    3. T1 写入更早的锚点、提交。

  结果：那笔单的 `expire_at` 仍按下单那刻的旧锚点算定，而活动当前锚点已被
  前移 —— 自助退款窗口被追溯关闭（`CancelFlow` 判假时静默不打款，订单停在
  `paid`）。

  修法：判定前先锁住该场全部 `payment_pending` 报名行。下单插入
  `payments_orders` 时 FK 会对 enrollments 父行取 `FOR KEY SHARE`，与 `FOR
  UPDATE` 冲突 —— 两条路径自此在这把锁上串行，且锁序仍是「events →
  enrollments」（与 `prepare_confirm` / 批量免缴一致，不成环）。

  本文件用确定性编排（消息握手 + pg_sleep 定界）复现该交错，不依赖偶发竞态。
  """

  use ExUnit.Case, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Events.Event
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Repo

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

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  test "守卫判定与并发下串行化：下单先提交则改锚点被拒（此前静默放行）",
       %{sandbox_owner: owner} do
    {workspace, event, admin, learner, enrollment} =
      unboxed(fn ->
        admin = Fixtures.platform_admin("anchor-race-admin")
        workspace = Fixtures.create_workspace(admin)

        event =
          EventFixtures.create_event(workspace, admin, %{
            title: "押金场",
            deposit_enabled: true,
            deposit_amount_cents: 6900,
            enrollment_policy: :open,
            ends_at: EventFixtures.days_from_now(8),
            registration_deadline: EventFixtures.days_from_now(8)
          })

        learner = Fixtures.register_user("anchor-race-learner")

        {:ok, enrollment} =
          Enrollment
          |> Ash.Changeset.for_create(:create_enrollment, %{
            event_id: event.id,
            user_id: learner.id
          })
          |> Ash.create(tenant: workspace.id, actor: learner)

        {workspace, event, admin, learner, enrollment}
      end)

    cleanup_on_exit(owner, workspace, event, [learner])

    assert enrollment.status == :payment_pending,
           "前提：下单要求报名为 payment_pending，实际 #{inspect(enrollment.status)}"

    test_pid = self()

    # T2：模拟下单事务——持 enrollment 行锁（下单链 `lock_for_order` 同一把），
    # 定界后插入 pending 押金单并提交。
    order_task =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT id FROM enrollments WHERE id = $1 FOR UPDATE", [
              Ecto.UUID.dump!(enrollment.id)
            ])

            send(test_pid, :enrollment_locked)
            Repo.query!("SELECT pg_sleep(0.8)", [])

            Repo.query!(
              """
              INSERT INTO payments_orders (id, enrollment_id, order_kind, amount_cents,
                provider, status, out_trade_no, expire_at, inserted_at, updated_at,
                workspace_id, tier_snapshot)
              VALUES (gen_random_uuid(), $1::uuid, 'deposit', 6900, 'wechat_native', 'pending',
                'anchor-race-txn', NOW() + INTERVAL '2 hours', NOW(), NOW(), $2::uuid,
                '{"name":"押金","amount_cents":6900}')
              """,
              [Ecto.UUID.dump!(enrollment.id), Ecto.UUID.dump!(workspace.id)]
            )
          end)
        end)
      end)

    receive do
      :enrollment_locked -> :ok
    after
      5_000 -> flunk("下单事务未能在 5s 内取得 enrollment 行锁（编排失败）")
    end

    # T1：管理员把 registration_deadline 前移。无修复时不取 enrollment 锁，
    # 守卫在 T2 提交前就判「无单」→ 放行；有修复时阻塞至 T2 提交 → 看到单 → 拒。
    admin_result =
      unboxed(fn ->
        event
        |> Ash.Changeset.for_update(:update, %{
          registration_deadline: EventFixtures.days_from_now(1)
        })
        |> Ash.update(actor: admin, tenant: workspace.id)
      end)

    Task.await(order_task, 15_000)

    assert {:error, %Ash.Error.Invalid{errors: errors}} = admin_result,
           "锚点前移必须被拒（实际放行），错误必须是冻结守卫"

    assert Enum.any?(
             errors,
             &match?(%BusinessError{code: "event_registration_deadline_frozen"}, &1)
           ),
           "期望 event_registration_deadline_frozen，实际：#{inspect(errors)}"

    # 库里锚点未被改动：仍是夹具那 8 天，而不是 T1 想写的 1 天
    # （裸 SQL 回 NaiveDateTime，归一后再比——同生产代码的踩坑点）
    unboxed(fn ->
      {:ok, %{rows: [[deadline]]}} =
        Repo.query("SELECT registration_deadline FROM events WHERE id = $1", [
          Ecto.UUID.dump!(event.id)
        ])

      deadline = DateTime.from_naive!(deadline, "Etc/UTC")

      assert DateTime.compare(deadline, EventFixtures.days_from_now(5)) == :gt,
             "锚点应仍是原值（约 8 天后），实际 #{inspect(deadline)}——说明 1 天那次写入落了"
    end)
  end

  test "无并发时正常前移仍被拦（回归：串行化没削弱守卫本身）",
       %{sandbox_owner: owner} do
    {workspace, event, admin, learner, enrollment} =
      unboxed(fn ->
        admin = Fixtures.platform_admin("anchor-seq-admin")
        workspace = Fixtures.create_workspace(admin)

        event =
          EventFixtures.create_event(workspace, admin, %{
            title: "押金场",
            deposit_enabled: true,
            deposit_amount_cents: 6900,
            enrollment_policy: :open,
            ends_at: EventFixtures.days_from_now(8),
            registration_deadline: EventFixtures.days_from_now(8)
          })

        learner = Fixtures.register_user("anchor-seq-learner")

        {:ok, enrollment} =
          Enrollment
          |> Ash.Changeset.for_create(:create_enrollment, %{
            event_id: event.id,
            user_id: learner.id
          })
          |> Ash.create(tenant: workspace.id, actor: learner)

        {workspace, event, admin, learner, enrollment}
      end)

    cleanup_on_exit(owner, workspace, event, [learner])

    unboxed(fn ->
      Repo.query!(
        """
        INSERT INTO payments_orders (id, enrollment_id, order_kind, amount_cents,
          provider, status, out_trade_no, expire_at, inserted_at, updated_at,
          workspace_id, tier_snapshot)
        VALUES (gen_random_uuid(), $1::uuid, 'deposit', 6900, 'wechat_native', 'paid',
          'anchor-seq-txn', NOW() + INTERVAL '2 hours', NOW(), NOW(), $2::uuid,
          '{"name":"押金","amount_cents":6900}')
        """,
        [Ecto.UUID.dump!(enrollment.id), Ecto.UUID.dump!(workspace.id)]
      )
    end)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             unboxed(fn ->
               event
               |> Ash.Changeset.for_update(:update, %{
                 registration_deadline: EventFixtures.days_from_now(1)
               })
               |> Ash.update(actor: admin, tenant: workspace.id)
             end)

    assert Enum.any?(
             errors,
             &match?(%BusinessError{code: "event_registration_deadline_frozen"}, &1)
           )
  end

  defp cleanup_on_exit(owner, workspace, event, users) do
    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)

      unboxed(fn ->
        Repo.query!(
          "DELETE FROM payments_orders WHERE enrollment_id IN (SELECT id FROM enrollments WHERE event_id = $1)",
          [Repo.uuid!(event.id)]
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

        Repo.query!("DELETE FROM workflow_definitions WHERE workspace_id = $1", [
          Repo.uuid!(workspace.id)
        ])

        Repo.query!("DELETE FROM workspaces WHERE id = $1", [Repo.uuid!(workspace.id)])

        Enum.each(users, fn user ->
          Repo.query!("DELETE FROM users WHERE id = $1", [Repo.uuid!(user.id)])
        end)
      end)
    end)
  end
end
