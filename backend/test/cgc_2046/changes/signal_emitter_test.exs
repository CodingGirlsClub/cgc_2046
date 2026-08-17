defmodule Cgc2046.Changes.SignalEmitterTest do
  @moduledoc """
  SignalEmitter 契约测试（plan 2026-08-14-003 Phase A.1 验收）：

  - after_action 事务内入队 SignalPublishWorker job（job 与终态同事务提交）
  - 幂等键派生：payload 注入 `idempotency_key = "<type>:<record_id>"`
  - `workspace_id` 由 emitter 从 record 注入（payload fn 不再自拼）
  - payload fn 调用契约：`fn changeset, record -> map`（context 可达）
  - `skip_unless` 谓词 false 跳过入队；payload 键在 emitter 边界归一为字符串
  - 入队失败（Oban insert raise）→ 事务回滚，终态不落库（Q6 事务性 outbox）
  """

  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Changes.SignalEmitter
  alias Cgc2046.Events.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Workers.SignalPublishWorker

  # 直挂契约测试用 opts（远程捕获须为 public 模块函数）
  def atom_keyed_payload(_changeset, record), do: %{enrollment_id: record.id, note: :atom_value}
  def skip_all(_changeset, _record), do: false

  # Jason 无法编码 tuple：经 Oban insert 的 jsonb 落库路径真实 raise（回滚用例）
  def unencodable_payload(_changeset, record), do: %{enrollment_id: record.id, bad: {1, 2}}

  test "event close：事务内入队 ended job，幂等键 <type>:<record_id> 与 workspace_id 注入" do
    admin = Fixtures.platform_admin("emitter-close-admin")
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin, %{title: "Emitter 大会"})

    assert {:ok, closed} =
             event
             |> Ash.Changeset.for_update(:close, %{}, actor: admin)
             |> Ash.update(tenant: workspace.id, actor: admin)

    assert closed.status == :closed

    assert_enqueued(
      worker: SignalPublishWorker,
      args: %{
        "signal_type" => "event.ended",
        "tenant" => workspace.id,
        "data" => %{
          "event_id" => event.id,
          "title" => "Emitter 大会",
          "idempotency_key" => "event.ended:" <> event.id,
          "workspace_id" => workspace.id
        }
      }
    )
  end

  test "payload fn 收到 changeset（context 可达）与 record：enrollment create 的 submitted job" do
    admin = Fixtures.platform_admin("emitter-create-admin")
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin, %{enrollment_policy: :request})
    learner = Fixtures.register_user("emitter-create-learner")

    assert {:ok, pending} =
             Enrollment
             |> Ash.Changeset.for_create(:create_enrollment, %{
               event_id: event.id,
               user_id: learner.id
             })
             |> Ash.create(tenant: workspace.id, actor: learner)

    assert_enqueued(
      worker: SignalPublishWorker,
      args: %{
        "signal_type" => "enrollment.submitted",
        "tenant" => workspace.id,
        "data" => %{
          "enrollment_id" => pending.id,
          "status" => "pending",
          # enrollment_policy 来自 changeset.context（prepare_create 写入）——
          # 证明 payload fn 的第一个实参是 changeset 而非裸 record
          "enrollment_policy" => "request",
          "idempotency_key" => "enrollment.submitted:" <> pending.id,
          "workspace_id" => workspace.id
        }
      }
    )
  end

  test "skip_unless 谓词 false → 跳过入队（request 策略 create 不发 completed）" do
    admin = Fixtures.platform_admin("emitter-skip-admin")
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin, %{enrollment_policy: :request})
    learner = Fixtures.register_user("emitter-skip-learner")

    assert {:ok, pending} =
             Enrollment
             |> Ash.Changeset.for_create(:create_enrollment, %{
               event_id: event.id,
               user_id: learner.id
             })
             |> Ash.create(tenant: workspace.id, actor: learner)

    assert pending.status == :pending

    assert_enqueued(
      worker: SignalPublishWorker,
      args: %{
        "signal_type" => "enrollment.submitted",
        "data" => %{"enrollment_id" => pending.id}
      }
    )

    refute_enqueued(
      worker: SignalPublishWorker,
      args: %{
        "signal_type" => "enrollment.completed",
        "data" => %{"enrollment_id" => pending.id}
      }
    )
  end

  test "直挂契约：payload 键归一字符串 + 双注入；skip_unless false 跳过入队" do
    admin = Fixtures.platform_admin("emitter-direct-admin")
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin, %{capacity: 10})
    learner = Fixtures.register_user("emitter-direct-learner")

    assert {:ok, enrollment} =
             Enrollment
             |> Ash.Changeset.for_create(:create_enrollment, %{
               event_id: event.id,
               user_id: learner.id
             })
             |> Ash.create(tenant: workspace.id, actor: learner)

    assert enrollment.status == :confirmed

    # 直挂 atom 键 payload fn 到 :cancel（自身无 emitter）：键在 emitter 边界字符串化，
    # idempotency_key / workspace_id 照常注入
    assert {:ok, cancelled} =
             enrollment
             |> Ash.Changeset.for_update(:cancel, %{})
             |> SignalEmitter.change(
               [type: "test.signal", payload: &__MODULE__.atom_keyed_payload/2],
               %{}
             )
             |> Ash.update(tenant: workspace.id, actor: learner)

    assert cancelled.status == :cancelled

    assert_enqueued(
      worker: SignalPublishWorker,
      args: %{
        "signal_type" => "test.signal",
        "tenant" => workspace.id,
        "data" => %{
          "enrollment_id" => enrollment.id,
          "note" => "atom_value",
          "idempotency_key" => "test.signal:" <> enrollment.id,
          "workspace_id" => workspace.id
        }
      }
    )

    # skip_unless false → 不入队（直挂对照）
    assert {:ok, enrollment2} =
             Enrollment
             |> Ash.Changeset.for_create(:create_enrollment, %{
               event_id: event.id,
               user_id: learner.id
             })
             |> Ash.create(tenant: workspace.id, actor: learner)

    assert {:ok, _} =
             enrollment2
             |> Ash.Changeset.for_update(:cancel, %{})
             |> SignalEmitter.change(
               [
                 type: "test.skipped",
                 payload: &__MODULE__.atom_keyed_payload/2,
                 skip_unless: &__MODULE__.skip_all/2
               ],
               %{}
             )
             |> Ash.update(tenant: workspace.id, actor: learner)

    refute_enqueued(worker: SignalPublishWorker, args: %{"signal_type" => "test.skipped"})
  end

  # Q6 事务性 outbox 的回滚面：入队失败（Oban insert 经 jsonb 落库对不可编码值
  # 真实 raise）必须连同数据层变更一起回滚——终态不落库、无孤儿 job，action
  # 可安全重试。异常类型随 Oban/Postgrex 编码路径而定，不在此锚定。
  test "入队失败 raise → 事务回滚：终态不落库、不产生孤儿 job" do
    admin = Fixtures.platform_admin("emitter-rollback-admin")
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin, %{capacity: 10})
    learner = Fixtures.register_user("emitter-rollback-learner")

    assert {:ok, enrollment} =
             Enrollment
             |> Ash.Changeset.for_create(:create_enrollment, %{
               event_id: event.id,
               user_id: learner.id
             })
             |> Ash.create(tenant: workspace.id, actor: learner)

    assert enrollment.status == :confirmed

    raised =
      try do
        enrollment
        |> Ash.Changeset.for_update(:cancel, %{})
        |> SignalEmitter.change(
          [type: "test.rollback", payload: &__MODULE__.unencodable_payload/2],
          %{}
        )
        |> Ash.update(tenant: workspace.id, actor: learner)

        nil
      rescue
        e -> e
      end

    assert raised != nil

    # 数据层变更随入队失败一并回滚：报名仍 confirmed（未取消）
    reloaded = Ash.get!(Enrollment, enrollment.id, authorize?: false)
    assert reloaded.status == :confirmed

    refute_enqueued(worker: SignalPublishWorker, args: %{"signal_type" => "test.rollback"})
  end
end
