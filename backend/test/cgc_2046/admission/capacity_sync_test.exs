defmodule Cgc2046.Admission.CapacitySyncTest do
  @moduledoc """
  ADR-0009 PR⑤ U7 展示投影同步回路测试（R15；KD2/KTD4）。

  - 信号发射：reserve / release / 支付超时释放端口（release_for_payment_expiry）
    三处在账本写成功后同事务入队 `capacity.synced`（权威 occupancy +
    sync_version，SignalEmitter 同款事务内 outbox）。
  - 投影幂等：同信号重投不改结果；旧 sync_version 不覆盖新值；乱序收敛到
    最大版本（条件 UPDATE `confirmed_count_sync_version < 新版本`）。
  - 端到端（AE1/AE2 全链）：报名 → 账本 +1 → 取 outbox 真实载荷投递 →
    offering `confirmed_count` 收敛到同一值；释放路径同口径回落。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.{CapacityLedger, Enrollment}
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Workflows.SignalPublishWorker
  alias Cgc2046.Workflows.SignalSubscriber

  @tier_id "66666666-6666-6666-6666-666666666666"

  describe "信号发射（R15：三发信号点收敛于账本写路径）" do
    test "报名占位后入队 capacity.synced（权威 occupancy + sync_version）" do
      {_workspace, _admin, event} = base_event("sync-reserve")
      learner = Fixtures.register_user("sync-reserve-learner")

      assert {:ok, enrollment} = create_enrollment(event, learner)
      assert enrollment.capacity_seq == 1

      assert [data] = synced_payloads(event.id)
      assert data["occupancy"] == 1
      assert data["sync_version"] == 1
      assert data["idempotency_key"] == "capacity.synced:#{event.id}:v1"
      assert data["workspace_id"] == event.workspace_id
    end

    test "取消释放后入队 capacity.synced（occupancy 回落值 + 版本续增）" do
      {workspace, _admin, event} = base_event("sync-release")
      learner = Fixtures.register_user("sync-release-learner")

      assert {:ok, enrollment} = create_enrollment(event, learner)

      assert {:ok, _} =
               enrollment
               |> Ash.Changeset.for_update(:cancel, %{})
               |> Ash.update(tenant: workspace.id, actor: learner)

      assert [_, data] = synced_payloads(event.id)
      assert data["occupancy"] == 0
      assert data["sync_version"] == 2
    end

    test "支付超时释放端口（release_for_payment_expiry）入队 capacity.synced" do
      {workspace, admin, _event} = base_event("sync-expiry")
      learner = Fixtures.register_user("sync-expiry-learner")

      paid_event =
        EventFixtures.create_event(workspace, admin, %{
          pricing_enabled: true,
          price_tiers: [%{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}]
        })

      assert {:ok, enrollment} =
               create_enrollment(paid_event, learner, %{tier_id: @tier_id})

      assert enrollment.status == :payment_pending
      assert :ok = Enrollment.release_for_payment_expiry(enrollment.id)

      assert [_, data] = synced_payloads(paid_event.id)
      assert data["occupancy"] == 0
      assert data["sync_version"] == 2
    end

    test "两次 reserve 发射的 capacity.synced idempotency_key 互不相同（#1 唯一性）" do
      {_workspace, _admin, event} = base_event("sync-keyuniq")

      assert {:ok, _} = create_enrollment(event, Fixtures.register_user("sync-keyuniq-a"))
      assert {:ok, _} = create_enrollment(event, Fixtures.register_user("sync-keyuniq-b"))

      # 键携带本次 CAS RETURNING 的 sync_version 后缀：逐次唯一，claim 型订阅方
      # 不会因恒定键永久丢信（payload 其余键/值语义不变）
      assert [first, second] = synced_payloads(event.id)
      assert first["sync_version"] == 1
      assert second["sync_version"] == 2
      assert first["idempotency_key"] == "capacity.synced:#{event.id}:v1"
      assert second["idempotency_key"] == "capacity.synced:#{event.id}:v2"
      refute first["idempotency_key"] == second["idempotency_key"]
    end
  end

  describe "投影幂等与乱序收敛（覆盖式 + sync_version 条件写）" do
    test "同一 capacity.synced 重投不改结果" do
      {_workspace, _admin, event} = base_event("sync-idem")

      payload = %{
        "event_id" => event.id,
        "occupancy" => 3,
        "sync_version" => 3,
        "idempotency_key" => "capacity.synced:#{event.id}",
        "workspace_id" => event.workspace_id
      }

      assert :ok = deliver_event_sync(payload)
      assert :ok = deliver_event_sync(payload)

      reloaded = Ash.get!(Cgc2046.Events.Event, event.id, authorize?: false)
      assert reloaded.confirmed_count == 3
      assert reloaded.confirmed_count_sync_version == 3
    end

    test "旧 sync_version 不覆盖新值；乱序收敛到最大版本" do
      {_workspace, _admin, event} = base_event("sync-order")

      for {occupancy, version} <- [{1, 1}, {3, 3}, {2, 2}] do
        assert :ok =
                 deliver_event_sync(%{
                   "event_id" => event.id,
                   "occupancy" => occupancy,
                   "sync_version" => version,
                   "idempotency_key" => "capacity.synced:#{event.id}",
                   "workspace_id" => event.workspace_id
                 })
      end

      reloaded = Ash.get!(Cgc2046.Events.Event, event.id, authorize?: false)
      assert reloaded.confirmed_count == 3
      assert reloaded.confirmed_count_sync_version == 3
    end

    test "course 投影同口径：写 courses 表且事件载荷不串表" do
      {workspace, admin, event} = base_event("sync-course")

      course = EventFixtures.create_course(workspace, admin, %{capacity: 5})

      assert :ok =
               Cgc2046.Workflows.SignalSubscriber.deliver(
                 Cgc2046.Courses.CapacityProjectionSubscriber,
                 %{
                   type: "capacity.synced",
                   data: %{
                     "course_id" => course.id,
                     "occupancy" => 2,
                     "sync_version" => 4,
                     "idempotency_key" => "capacity.synced:#{course.id}",
                     "workspace_id" => workspace.id
                   }
                 }
               )

      reloaded = Ash.get!(Cgc2046.Courses.Course, course.id, authorize?: false)
      assert reloaded.confirmed_count == 2
      assert reloaded.confirmed_count_sync_version == 4

      # 对称侧：event 载荷投递给 Courses 订阅方 = no-op，不串表
      assert :ok =
               Cgc2046.Workflows.SignalSubscriber.deliver(
                 Cgc2046.Courses.CapacityProjectionSubscriber,
                 %{
                   type: "capacity.synced",
                   data: %{
                     "event_id" => event.id,
                     "occupancy" => 9,
                     "sync_version" => 9,
                     "idempotency_key" => "capacity.synced:#{event.id}",
                     "workspace_id" => workspace.id
                   }
                 }
               )

      assert Ash.get!(Cgc2046.Events.Event, event.id, authorize?: false).confirmed_count == 0
    end
  end

  describe "端到端（AE1/AE2 全链）" do
    test "报名 → 账本 +1 → 投递 outbox 真实载荷 → 投影一致；取消 → 回落" do
      {workspace, _admin, event} = base_event("sync-e2e")
      learner = Fixtures.register_user("sync-e2e-learner")

      assert {:ok, enrollment} = create_enrollment(event, learner)
      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert ledger.occupancy == 1

      # 取事务内 outbox 真实载荷投递（生产路径 = SignalPublishWorker 发布同一份）
      assert [reserve_data] = synced_payloads(event.id)
      assert :ok = deliver_event_sync(reserve_data)

      reloaded = Ash.get!(Cgc2046.Events.Event, event.id, authorize?: false)
      assert reloaded.confirmed_count == 1
      assert reloaded.confirmed_count == ledger.occupancy
      assert reloaded.confirmed_count_sync_version == ledger.sync_version

      assert {:ok, _} =
               enrollment
               |> Ash.Changeset.for_update(:cancel, %{})
               |> Ash.update(tenant: workspace.id, actor: learner)

      assert [_, release_data] = synced_payloads(event.id)
      assert :ok = deliver_event_sync(release_data)

      reloaded = Ash.get!(Cgc2046.Events.Event, event.id, authorize?: false)
      assert reloaded.confirmed_count == 0
      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
      assert reloaded.confirmed_count_sync_version == ledger.sync_version
    end

    test "AE2：收费 payment_pending 占位 → 订单超时过期 → 投影收敛到 0" do
      {workspace, admin, _event} = base_event("sync-ae2")
      learner = Fixtures.register_user("sync-ae2-learner")

      paid_event =
        EventFixtures.create_event(workspace, admin, %{
          pricing_enabled: true,
          price_tiers: [%{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}]
        })

      assert {:ok, enrollment} =
               create_enrollment(paid_event, learner, %{tier_id: @tier_id})

      assert [reserve_data] = synced_payloads(paid_event.id)
      assert :ok = deliver_event_sync(reserve_data)

      assert Ash.get!(Cgc2046.Events.Event, paid_event.id, authorize?: false).confirmed_count ==
               1

      assert :ok = Enrollment.release_for_payment_expiry(enrollment.id)

      assert [_, release_data] = synced_payloads(paid_event.id)
      assert :ok = deliver_event_sync(release_data)

      reloaded = Ash.get!(Cgc2046.Events.Event, paid_event.id, authorize?: false)
      assert reloaded.confirmed_count == 0
      assert {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, paid_event.id)
      assert ledger.occupancy == 0
      assert reloaded.confirmed_count_sync_version == ledger.sync_version
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp base_event(tag) do
    admin = Fixtures.platform_admin("#{tag}-admin")
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin, %{capacity: 10})
    {workspace, admin, event}
  end

  defp create_enrollment(event, user, attrs \\ %{}) do
    attrs = Map.merge(%{event_id: event.id, user_id: user.id}, attrs)

    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, attrs)
    |> Ash.create(tenant: event.workspace_id, actor: user)
  end

  # 按 event_id 过滤本测试入队的 capacity.synced 载荷（按入队序）；
  # 锚定 event_id——套件内其他测试残留 job 不影响匹配（count_enqueued 同款纪律）
  defp synced_payloads(event_id) do
    [worker: SignalPublishWorker]
    |> all_enqueued()
    |> Enum.filter(
      &(&1.args["signal_type"] == "capacity.synced" &&
          get_in(&1.args, ["data", "event_id"]) == event_id)
    )
    # all_enqueued 不保证入队序（Oban 查询无序），按载荷 sync_version 排序
    |> Enum.map(& &1.args["data"])
    |> Enum.sort_by(& &1["sync_version"])
  end

  defp deliver_event_sync(data) do
    SignalSubscriber.deliver(Cgc2046.Events.CapacityProjectionSubscriber, %{
      type: "capacity.synced",
      data: data
    })
  end
end
