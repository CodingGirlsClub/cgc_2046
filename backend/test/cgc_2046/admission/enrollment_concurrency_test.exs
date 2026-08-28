defmodule Cgc2046.Admission.EnrollmentConcurrencyTest do
  # 不走 DataCase 默认 sandbox：本测试的 unboxed 清理须在 sandbox 事务结束后
  # 执行——应用级订阅方（NotificationSubscriber，E-2 #47）在共享 sandbox 事务
  # 内写 signal_idempotency claim，其 workspaces 外键 KEY SHARE 锁持有至事务
  # 结束；不先停 owner，清理里的 unboxed DELETE FROM workspaces 会阻塞到连接
  # 超时。故自管 owner 生命周期，清理回调先 stop_owner 再删真实行。
  use ExUnit.Case, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.{Enrollment, InviteBatch}
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.MiniprogramFixtures.Barrier

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Cgc2046.Repo, shared: true)

    on_exit(fn ->
      # 幂等容错：cleanup_on_exit 可能已提前 stop_owner（释放外键锁），
      # 已停止时 GenServer.stop 抛 noproc exit（{:noproc, _} 或 :noproc），忽略。
      try do
        Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
      catch
        :exit, {:noproc, _} -> :ok
        :exit, :noproc -> :ok
      end
    end)

    %{sandbox_owner: owner}
  end

  test "capacity=1 的两个并发 open 报名恰好一个成功", %{sandbox_owner: owner} do
    {admin, workspace, event, users} =
      unboxed(fn ->
        admin = Fixtures.platform_admin("capacity-race-admin")
        workspace = Fixtures.create_workspace(admin)
        event = EventFixtures.create_event(workspace, admin, %{capacity: 1})

        users = [
          Fixtures.register_user("capacity-race-a"),
          Fixtures.register_user("capacity-race-b")
        ]

        {admin, workspace, event, users}
      end)

    cleanup_on_exit(owner, workspace.id, [admin | users])
    barrier = start_supervised!({Barrier, 2})

    results = race_enrollments(event, users, barrier, %{})
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1

    # ADR-0009 PR⑤ U6 口径平移：占位计数权威 = 名额账本 occupancy（原 events.confirmed_count）
    assert EventFixtures.ledger_occupancy(event) == 1
  end

  test "quota=1 的两个并发 invite_only 报名恰好消费一次", %{sandbox_owner: owner} do
    invite_code = "RACE_#{Ecto.UUID.generate()}"

    {admin, workspace, event, batch, users} =
      unboxed(fn ->
        admin = Fixtures.platform_admin("quota-race-admin")
        workspace = Fixtures.create_workspace(admin)
        event = EventFixtures.create_event(workspace, admin, %{enrollment_policy: :invite_only})

        batch =
          InviteBatch
          |> Ash.Changeset.for_create(:create, %{
            event_id: event.id,
            invite_code: invite_code,
            quota: 1
          })
          |> Ash.create!(tenant: workspace.id, actor: admin)

        users = [Fixtures.register_user("quota-race-a"), Fixtures.register_user("quota-race-b")]
        {admin, workspace, event, batch, users}
      end)

    cleanup_on_exit(owner, workspace.id, [admin | users])
    barrier = start_supervised!({Barrier, 2})

    results = race_enrollments(event, users, barrier, %{invite_code: invite_code})
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    assert Ash.get!(InviteBatch, batch.id, authorize?: false).remaining_quota == 0
  end

  defp race_enrollments(event, users, barrier, extra_attrs) do
    users
    |> Enum.map(fn user ->
      Task.async(fn ->
        unboxed(fn ->
          Barrier.arrive(barrier)

          Enrollment
          |> Ash.Changeset.for_create(
            :create_enrollment,
            Map.merge(%{event_id: event.id, user_id: user.id}, extra_attrs)
          )
          |> Ash.create(tenant: event.workspace_id, actor: user)
        end)
      end)
    end)
    |> Task.await_many(15_000)
  end

  defp cleanup_on_exit(owner, workspace_id, users) do
    on_exit(fn ->
      # 先结束 sandbox 事务（回滚订阅方 claim 等共享写入）→ 释放 signal_idempotency
      # 对 workspaces 行的外键 KEY SHARE 锁；否则 unboxed DELETE 阻塞至连接超时。
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)

      unboxed(fn ->
        Cgc2046.Repo.query!(
          "DELETE FROM membership_roles WHERE membership_id IN (SELECT id FROM workspace_memberships WHERE workspace_id = $1)",
          [Ecto.UUID.dump!(workspace_id)]
        )

        Cgc2046.Repo.query!("DELETE FROM workspace_memberships WHERE workspace_id = $1", [
          Ecto.UUID.dump!(workspace_id)
        ])

        Cgc2046.Repo.query!("DELETE FROM events WHERE workspace_id = $1", [
          Ecto.UUID.dump!(workspace_id)
        ])

        # #242：workspace create 的 LogAdminAction 落 admin_action_logs（无 FK 不级联），
        # unboxed 真实提交会累积；cleanup 必须显式清理，否则污染共享 DB 全局表。
        Cgc2046.Repo.query!(
          "DELETE FROM admin_action_logs WHERE target_type = 'workspace' AND target_id = $1",
          [Ecto.UUID.dump!(workspace_id)]
        )

        Cgc2046.Repo.query!("DELETE FROM workspaces WHERE id = $1", [
          Ecto.UUID.dump!(workspace_id)
        ])

        Enum.each(users, fn user ->
          Cgc2046.Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(user.id)])
        end)
      end)
    end)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Cgc2046.Repo, fun)
end
