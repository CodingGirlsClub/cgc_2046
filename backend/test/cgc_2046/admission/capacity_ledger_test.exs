defmodule Cgc2046.Admission.CapacityLedgerTest do
  @moduledoc """
  名额账本（ADR-0009 PR⑤ U6；R12-R16；KD2；KTD4/KTD5/KTD7）。

  - 占位 CAS 收编账本行：免费 open 报名 occupancy +1，`capacity_seq` = 账本
    occupancy（R14）。
  - 并发不超卖：N 并发报名 capacity=N-1，恰好 N-1 成功（口径自
    enrollment_concurrency_test 平移到账本行）。
  - 懒建兜底（KTD5/AE3）：无账本行时报名成功，建行字段取自 Offering 最新值。
  - 守卫复刻：deadline 过后 / status 非 open 报名被拒；confirm 路径在账本
    CAS 层复刻同一拒绝（R14）。
  - 编辑同步（R16）：capacity 调大/调小/NULL↔有限、deadline 变更经
    `offering.capacity_changed` 同步账本缓存；调小低于 occupancy 放行，新单
    由账本 CAS 拒（AE4 前半）。
  - invite_only 双 CAS 锁序（KTD7）：账本行 → invite_batches 行；配额不足
    整体回滚，occupancy 不落。
  - 重投/乱序幂等：唯一索引吸收建行冲突，回查式覆盖收敛（KTD5）。

  sandbox 纪律同 enrollment_concurrency_test：自管 owner，并发组 unboxed
  真实提交，清理先 stop_owner 再删真实行。
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.{CapacityLedger, CapacityLedgerSubscriber, Enrollment, InviteBatch}
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.MiniprogramFixtures.Barrier
  alias Cgc2046.Workflows.SignalPublishWorker
  alias Cgc2046.Workflows.SignalSubscriber

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

  describe "占位（R14：CAS 收编账本行）" do
    test "免费 open 报名账本 occupancy +1，capacity_seq 返回账本 occupancy" do
      admin = Fixtures.platform_admin("ledger-open-admin")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{capacity: 3})
      learner = Fixtures.register_user("ledger-open-learner")

      assert {:ok, enrollment} = create_enrollment(event, learner)
      assert enrollment.status == :confirmed
      assert enrollment.capacity_seq == 1

      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert ledger.occupancy == 1
      assert ledger.sync_version == 1
      assert ledger.status == :open
    end

    test "取消释放回账本：occupancy 回落、sync_version 续增、可重新报名" do
      admin = Fixtures.platform_admin("ledger-release-admin")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{capacity: 1})
      learner = Fixtures.register_user("ledger-release-learner")

      assert {:ok, enrollment} = create_enrollment(event, learner)

      assert {:ok, cancelled} =
               enrollment
               |> Ash.Changeset.for_update(:cancel, %{})
               |> Ash.update(tenant: workspace.id, actor: learner)

      assert cancelled.status == :cancelled
      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert ledger.occupancy == 0
      assert ledger.sync_version == 2

      assert {:ok, re} = create_enrollment(event, learner)
      assert re.capacity_seq == 1
    end
  end

  describe "并发不超卖（口径平移：账本行 CAS）" do
    test "capacity=2 的三个并发 open 报名恰好两个成功", %{sandbox_owner: owner} do
      {admin, workspace, event, users} =
        unboxed(fn ->
          admin = Fixtures.platform_admin("ledger-race-admin")
          workspace = Fixtures.create_workspace(admin)
          event = EventFixtures.create_event(workspace, admin, %{capacity: 2})

          users = [
            Fixtures.register_user("ledger-race-a"),
            Fixtures.register_user("ledger-race-b"),
            Fixtures.register_user("ledger-race-c")
          ]

          {admin, workspace, event, users}
        end)

      cleanup_on_exit(owner, workspace.id, [admin | users])
      barrier = start_supervised!({Barrier, 3})

      results = race_enrollments(event, users, barrier)
      assert Enum.count(results, &match?({:ok, _}, &1)) == 2
      assert Enum.count(results, &match?({:error, _}, &1)) == 1

      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert ledger.occupancy == 2
    end
  end

  describe "懒建兜底（KTD5/AE3）" do
    test "无账本行时报名成功，建行字段取自 Offering 最新值" do
      admin = Fixtures.platform_admin("ledger-lazy-admin")
      workspace = Fixtures.create_workspace(admin)
      deadline = EventFixtures.days_from_now(3)

      event =
        EventFixtures.create_event(workspace, admin, %{
          capacity: 5,
          registration_deadline: deadline
        })

      # 布置走 force_open 裸 SQL，无 launched 信号 → 断言无账本行
      assert {:error, :not_found} = CapacityLedger.fetch_by_offering(:event, event.id)

      learner = Fixtures.register_user("ledger-lazy-learner")
      assert {:ok, enrollment} = create_enrollment(event, learner)
      assert enrollment.capacity_seq == 1

      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert ledger.workspace_id == workspace.id
      assert ledger.status == :open
      assert ledger.capacity == 5
      assert ledger.occupancy == 1

      reloaded = Ash.get!(event.__struct__, event.id, authorize?: false)
      assert ledger.registration_deadline == reloaded.registration_deadline
    end
  end

  describe "守卫复刻（R14 三条件原样）" do
    test "deadline 过后报名被拒（eligible_target 活值守卫）" do
      admin = Fixtures.platform_admin("ledger-dl-admin")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      learner = Fixtures.register_user("ledger-dl-learner")

      # 布置纪律同 set_confirmed_count：裸 SQL 置位而非被测对象
      {:ok, _} =
        Cgc2046.Repo.query(
          "UPDATE events SET registration_deadline = NOW() - INTERVAL '1 hour' WHERE id = $1",
          [Ecto.UUID.dump!(event.id)]
        )

      assert_business_code(
        create_enrollment(event, learner),
        "enrollment_target_not_open_or_registration_closed"
      )
    end

    test "status 非 open（closed / cancelled）报名被拒" do
      admin = Fixtures.platform_admin("ledger-status-admin")
      workspace = Fixtures.create_workspace(admin)
      closed_event = EventFixtures.create_event(workspace, admin, %{title: "closed"})
      cancelled_event = EventFixtures.create_event(workspace, admin, %{title: "cancelled"})

      {:ok, _} =
        closed_event
        |> Ash.Changeset.for_update(:close, %{})
        |> Ash.update(tenant: workspace.id, actor: admin)

      {:ok, _} =
        cancelled_event
        |> Ash.Changeset.for_update(:cancel, %{})
        |> Ash.update(tenant: workspace.id, actor: admin)

      learner = Fixtures.register_user("ledger-status-learner")

      assert_business_code(
        create_enrollment(closed_event, learner),
        "enrollment_target_not_open_or_registration_closed"
      )

      assert_business_code(
        create_enrollment(cancelled_event, learner),
        "enrollment_target_not_open_or_registration_closed"
      )
    end

    test "confirm 路径在账本 CAS 层复刻 status 守卫（ended 已同步）" do
      admin = Fixtures.platform_admin("ledger-confirm-admin")
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{
          capacity: 1,
          enrollment_policy: :request
        })

      learner = Fixtures.register_user("ledger-confirm-learner")
      assert {:ok, pending} = create_enrollment(event, learner)

      {:ok, _} =
        event
        |> Ash.Changeset.for_update(:close, %{})
        |> Ash.update(tenant: workspace.id, actor: admin)

      # ended 信号投递 → 账本回查同步 status=closed（同码入口 SignalSubscriber.deliver）
      assert :ok =
               SignalSubscriber.deliver(CapacityLedgerSubscriber, %{
                 type: "event.ended",
                 data: %{"event_id" => event.id}
               })

      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert ledger.status == :closed

      assert_business_code(
        confirm(pending, admin),
        "enrollment_capacity_full_or_registration_closed"
      )
    end

    test "confirm 路径在账本 CAS 层复刻 deadline 守卫（capacity_changed 已同步）" do
      admin = Fixtures.platform_admin("ledger-confirm-dl-admin")
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{
          capacity: 1,
          enrollment_policy: :request
        })

      learner = Fixtures.register_user("ledger-confirm-dl-learner")
      assert {:ok, pending} = create_enrollment(event, learner)

      # 报名后组织者把截止改到过去（元数据编辑不拦截），信号同步账本缓存
      {:ok, _} =
        event
        |> Ash.Changeset.for_update(:update, %{
          registration_deadline: DateTime.add(DateTime.utc_now(), -1, :hour)
        })
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert :ok =
               SignalSubscriber.deliver(CapacityLedgerSubscriber, %{
                 type: "offering.capacity_changed",
                 data: %{"event_id" => event.id}
               })

      assert_business_code(
        confirm(pending, admin),
        "enrollment_capacity_full_or_registration_closed"
      )
    end
  end

  describe "编辑同步（R16：offering.capacity_changed）" do
    test "capacity 调大 / 调小 / NULL↔有限、deadline 变更同步账本缓存" do
      admin = Fixtures.platform_admin("ledger-sync-admin")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{capacity: 2})
      learner = Fixtures.register_user("ledger-sync-learner")

      assert {:ok, _} = create_enrollment(event, learner)

      # 调大 2 → 10
      {:ok, _} = update_event(event, workspace, admin, %{capacity: 10})
      assert_capacity_changed_enqueued(event)
      deliver_capacity_changed(event)

      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert ledger.capacity == 10
      assert ledger.occupancy == 1

      # 有限 → NULL
      {:ok, _} = update_event(event, workspace, admin, %{capacity: nil})
      deliver_capacity_changed(event)

      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert is_nil(ledger.capacity)

      # NULL → 有限
      {:ok, _} = update_event(event, workspace, admin, %{capacity: 4})
      deliver_capacity_changed(event)

      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert ledger.capacity == 4

      # deadline 变更
      new_deadline = EventFixtures.days_from_now(14)
      {:ok, _} = update_event(event, workspace, admin, %{registration_deadline: new_deadline})
      deliver_capacity_changed(event)

      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      reloaded = Ash.get!(event.__struct__, event.id, authorize?: false)
      assert ledger.registration_deadline == reloaded.registration_deadline

      # 仅改 title 不发 capacity_changed：update 前后该事件容量信号 job 数不变
      before = count_capacity_changed_enqueued(event.id)
      {:ok, _} = update_event(event, workspace, admin, %{title: "no signal"})
      assert count_capacity_changed_enqueued(event.id) == before
    end

    test "调小低于 occupancy 放行，新单由账本 CAS 拒（AE4 前半）" do
      admin = Fixtures.platform_admin("ledger-shrink-admin")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{capacity: 5})

      for name <- ["ledger-shrink-a", "ledger-shrink-b", "ledger-shrink-c"] do
        assert {:ok, _} = create_enrollment(event, Fixtures.register_user(name))
      end

      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert ledger.occupancy == 3

      # 调小 5 → 2（低于 occupancy=3）：编辑放行（confirmed_count check constraint 已删，R16）
      {:ok, _} = update_event(event, workspace, admin, %{capacity: 2})
      deliver_capacity_changed(event)

      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert ledger.capacity == 2
      assert ledger.occupancy == 3

      # 新单被账本 CAS 拒，存量占位不受影响
      latecomer = Fixtures.register_user("ledger-shrink-late")

      assert_business_code(
        create_enrollment(event, latecomer),
        "enrollment_capacity_full_or_registration_closed"
      )

      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert ledger.occupancy == 3
    end
  end

  describe "invite_only 双 CAS 锁序（KTD7）" do
    test "配额不足时整体回滚：账本 occupancy 不落、配额保持" do
      admin = Fixtures.platform_admin("ledger-invite-admin")
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{
          capacity: 2,
          enrollment_policy: :invite_only
        })

      batch =
        InviteBatch
        |> Ash.Changeset.for_create(:create, %{
          event_id: event.id,
          invite_code: "LEDGER_ROLLBACK",
          quota: 1
        })
        |> Ash.create!(tenant: workspace.id, actor: admin)

      first = Fixtures.register_user("ledger-invite-first")

      assert {:ok, _} = create_enrollment(event, first, %{invite_code: "LEDGER_ROLLBACK"})
      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert ledger.occupancy == 1
      assert Ash.get!(InviteBatch, batch.id, authorize?: false).remaining_quota == 0

      # 第二人：账本占位 CAS 成功（capacity=2 有余）但配额 CAS 失败 → 事务整体回滚
      second = Fixtures.register_user("ledger-invite-second")

      assert_business_code(
        create_enrollment(event, second, %{invite_code: "LEDGER_ROLLBACK"}),
        "enrollment_invite_quota_unavailable"
      )

      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert ledger.occupancy == 1
      assert Ash.get!(InviteBatch, batch.id, authorize?: false).remaining_quota == 0
    end

    test "capacity 占满反方向：账本 CAS 先拒，另一有效邀请码配额不消耗" do
      admin = Fixtures.platform_admin("ledger-invfull-admin")
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{
          capacity: 1,
          enrollment_policy: :invite_only
        })

      InviteBatch
      |> Ash.Changeset.for_create(:create, %{
        event_id: event.id,
        invite_code: "LEDGER_FULL_FILL",
        quota: 1
      })
      |> Ash.create!(tenant: workspace.id, actor: admin)

      hold_batch =
        InviteBatch
        |> Ash.Changeset.for_create(:create, %{
          event_id: event.id,
          invite_code: "LEDGER_FULL_HOLD",
          quota: 1
        })
        |> Ash.create!(tenant: workspace.id, actor: admin)

      # 第一笔占满 capacity=1 的唯一席位
      first = Fixtures.register_user("ledger-invfull-first")
      assert {:ok, _} = create_enrollment(event, first, %{invite_code: "LEDGER_FULL_FILL"})
      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert ledger.occupancy == 1

      # 第二人持另一有效邀请码：KTD7 锁序账本行先行——reserve CAS 失败整体回滚，
      # consume_invite_quota 不生效，hold_batch 配额保持不消耗
      second = Fixtures.register_user("ledger-invfull-second")

      assert_business_code(
        create_enrollment(event, second, %{invite_code: "LEDGER_FULL_HOLD"}),
        "enrollment_capacity_full_or_registration_closed"
      )

      assert Ash.get!(InviteBatch, hold_batch.id, authorize?: false).remaining_quota == 1
      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert ledger.occupancy == 1
    end
  end

  describe "重投 / 乱序幂等（KTD5：唯一索引吸收）" do
    test "launched 重投放行一行且不重置 occupancy" do
      admin = Fixtures.platform_admin("ledger-idem-admin")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{capacity: 3})
      learner = Fixtures.register_user("ledger-idem-learner")

      assert {:ok, _} = create_enrollment(event, learner)
      assert {:ok, %{occupancy: 1}} = CapacityLedger.fetch_by_offering(:event, event.id)

      signal = %{type: "event.launched", data: %{"event_id" => event.id}}

      assert :ok = SignalSubscriber.deliver(CapacityLedgerSubscriber, signal)
      assert :ok = SignalSubscriber.deliver(CapacityLedgerSubscriber, signal)

      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert ledger.occupancy == 1
      assert ledger.capacity == 3
    end

    test "乱序收敛：ended 后重投 launched 回查最新状态不复活 open" do
      admin = Fixtures.platform_admin("ledger-order-admin")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      {:ok, _} =
        event
        |> Ash.Changeset.for_update(:close, %{})
        |> Ash.update(tenant: workspace.id, actor: admin)

      # ended 先到：建行即 closed（回查 Offering 最新值）
      assert :ok =
               SignalSubscriber.deliver(CapacityLedgerSubscriber, %{
                 type: "event.ended",
                 data: %{"event_id" => event.id}
               })

      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert ledger.status == :closed

      # 乱序的 launched 迟投：回查仍读 closed，覆盖式收敛
      assert :ok =
               SignalSubscriber.deliver(CapacityLedgerSubscriber, %{
                 type: "event.launched",
                 data: %{"event_id" => event.id}
               })

      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert ledger.status == :closed
    end

    test "course 信号同口径：course.launched 建行、course.ended 同步 closed" do
      admin = Fixtures.platform_admin("ledger-course-admin")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{capacity: 7})

      assert :ok =
               SignalSubscriber.deliver(CapacityLedgerSubscriber, %{
                 type: "course.launched",
                 data: %{"course_id" => course.id}
               })

      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:course, course.id)
      assert ledger.status == :open
      assert ledger.capacity == 7

      {:ok, _} =
        course
        |> Ash.Changeset.for_update(:close, %{})
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert :ok =
               SignalSubscriber.deliver(CapacityLedgerSubscriber, %{
                 type: "course.ended",
                 data: %{"course_id" => course.id}
               })

      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:course, course.id)
      assert ledger.status == :closed
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # Ash 把 changeset 业务错误包进 %Ash.Error.Invalid{errors: [...]}（enrollment_test
  # 同款形状）；按 BusinessError.code 断言，与文案解耦。
  defp assert_business_code({:error, %Ash.Error.Invalid{errors: errors}}, expected) do
    assert Enum.any?(errors, &match?(%Cgc2046.Errors.BusinessError{code: ^expected}, &1)),
           "expected BusinessError code #{expected}, got: #{inspect(errors)}"
  end

  defp create_enrollment(target, user, attrs \\ %{}) do
    target_key = if target.__struct__ == Cgc2046.Events.Event, do: :event_id, else: :course_id
    attrs = Map.merge(%{target_key => target.id, user_id: user.id}, attrs)

    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, attrs)
    |> Ash.create(tenant: target.workspace_id, actor: user)
  end

  defp confirm(enrollment, actor) do
    enrollment
    |> Ash.Changeset.for_update(:confirm_enrollment, %{})
    |> Ash.update(tenant: enrollment.workspace_id, actor: actor)
  end

  defp update_event(event, workspace, actor, attrs) do
    event
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(tenant: workspace.id, actor: actor)
  end

  defp deliver_capacity_changed(event) do
    assert :ok =
             SignalSubscriber.deliver(CapacityLedgerSubscriber, %{
               type: "offering.capacity_changed",
               data: %{"event_id" => event.id}
             })
  end

  # 按 (signal_type, event_id) 计数：同测试内多次编辑各自入队，断言锚定 event_id
  # 比较前后差值（count_enqueued 同款纪律，enrollment_test 先例）。
  defp count_capacity_changed_enqueued(event_id) do
    [worker: SignalPublishWorker]
    |> all_enqueued()
    |> Enum.count(
      &(&1.args["signal_type"] == "offering.capacity_changed" &&
          get_in(&1.args, ["data", "event_id"]) == event_id)
    )
  end

  # 断言 update 动作真实入队 offering.capacity_changed（SignalEmitter 事务内 outbox）；
  # 锚定 event_id——套件内残留 job 不影响匹配（count_enqueued 同款纪律）。
  defp assert_capacity_changed_enqueued(event) do
    assert_enqueued(
      worker: SignalPublishWorker,
      args: %{"signal_type" => "offering.capacity_changed", "data" => %{"event_id" => event.id}}
    )
  end

  defp race_enrollments(event, users, barrier) do
    users
    |> Enum.map(fn user ->
      Task.async(fn ->
        unboxed(fn ->
          Barrier.arrive(barrier)
          create_enrollment(event, user)
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

        # 账本行经 workspace 外键 delete_all 级联；显式清理防约束漂移时静默残留。
        Cgc2046.Repo.query!("DELETE FROM admission_capacity_ledgers WHERE workspace_id = $1", [
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
