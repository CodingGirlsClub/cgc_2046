defmodule Cgc2046.AsyncSignalTest do
  @moduledoc """
  E-2 #47 验收：异步衍生 Signal 订阅方（NotificationSubscriber）端到端测试。

  全栈异步路径：Enrollment after_transaction 发布 → 内存信号总线 →
  NotificationSubscriber 订阅回调（独立进程）→ SignalIdempotency.claim →
  Oban NotificationWorker 入队。测试不直接调订阅方内部逻辑完成主路径，
  最终一致断言用 assert_enqueued/2（10ms 轮询）。

  重复投递去重：同 idempotency_key 经真实总线重复投递；spy 订阅证明两条投递
  均已到达订阅方，屏障信号证明订阅方已处理完两条投递，最终状态只有一条
  通知任务 + 一行 signal_idempotency 记录（claim-first：无论第二条何时被
  消费，already_claimed 都跳过副作用）。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.NotificationSubscriber
  alias Cgc2046.Workflows.{JidoAdapter, SignalIdempotency}
  alias Cgc2046.Workers.NotificationWorker

  require Ash.Query

  describe "通知订阅方 E2E" do
    test "submitted（request 策略）→ Owner/Admin 收到待审批任务；审批确认后 completed → 学员收到报名成功任务" do
      admin = Fixtures.platform_admin("signal-request-admin")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("signal-request-learner")

      event = EventFixtures.create_event(workspace, admin, %{enrollment_policy: :request})

      insert_identity(admin.id, "signal-request-admin-openid")
      insert_identity(learner.id, "signal-request-learner-openid")

      {:ok, enrollment} = create_enrollment(event, learner)
      assert enrollment.status == :pending

      # 异步最终一致：submitted → Owner/Admin 待审批通知任务
      assert_enqueued(
        [
          worker: NotificationWorker,
          args: %{
            "user_id" => admin.id,
            "template_key" => "enrollment_submitted",
            "enrollment_id" => enrollment.id,
            "data" => %{"enrollment_id" => enrollment.id, "title" => event.title}
          }
        ],
        2_000
      )

      assert [%{args: submitted_args}] =
               all_enqueued(
                 worker: NotificationWorker,
                 args: %{
                   "template_key" => "enrollment_submitted",
                   "enrollment_id" => enrollment.id
                 }
               )

      assert submitted_args["idempotency_key"] == "enrollment.submitted:" <> enrollment.id

      # request 提交尚无 completed 信号：报名学员没有报名成功任务
      refute_enqueued(
        [args: %{"template_key" => "enrollment_completed", "enrollment_id" => enrollment.id}],
        300
      )

      # 审批通过 → completed → 学员本人报名成功任务（含活动标题）
      {:ok, _} = confirm(enrollment, admin)

      assert_enqueued(
        [
          worker: NotificationWorker,
          args: %{
            "user_id" => learner.id,
            "template_key" => "enrollment_completed",
            "enrollment_id" => enrollment.id,
            "idempotency_key" => "enrollment.completed:" <> enrollment.id,
            "data" => %{"enrollment_id" => enrollment.id, "title" => event.title}
          }
        ],
        2_000
      )
    end

    test "open 策略报名直接 confirmed：completed 通知学员，submitted 不产生待审批通知" do
      admin = Fixtures.platform_admin("signal-open-admin")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("signal-open-learner")

      event = EventFixtures.create_event(workspace, admin)

      insert_identity(admin.id, "signal-open-admin-openid")
      insert_identity(learner.id, "signal-open-learner-openid")

      {:ok, enrollment} = create_enrollment(event, learner)
      assert enrollment.status == :confirmed

      assert_enqueued(
        [
          worker: NotificationWorker,
          args: %{
            "user_id" => learner.id,
            "template_key" => "enrollment_completed",
            "enrollment_id" => enrollment.id,
            "data" => %{"enrollment_id" => enrollment.id, "title" => event.title}
          }
        ],
        2_000
      )

      # submitted 信号确实发布过（生产者对全策略发布），但无待审批语义 → 不通知 Owner/Admin
      refute_enqueued([args: %{"template_key" => "enrollment_submitted"}], 300)
    end
  end

  describe "幂等去重" do
    test "同 idempotency_key 经真实总线重复投递只执行一次" do
      admin = Fixtures.platform_admin("signal-dup-admin")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("signal-dup-learner")

      event = EventFixtures.create_event(workspace, admin)
      insert_identity(learner.id, "signal-dup-learner-openid")

      {:ok, enrollment} = create_enrollment(event, learner)

      # 原始 completed 信号消费完成（通知任务已入队）
      assert_enqueued(
        [
          worker: NotificationWorker,
          args: %{"template_key" => "enrollment_completed", "enrollment_id" => enrollment.id}
        ],
        2_000
      )

      payload = completed_payload(enrollment, event)
      subscribe_spy()

      # 真实重复投递两条（payload 与生产者一致，含同一 idempotency_key）
      assert :ok = JidoAdapter.publish("enrollment.completed", payload, workspace.id)
      assert :ok = JidoAdapter.publish("enrollment.completed", payload, workspace.id)

      # spy 证明两条投递均已到达订阅方
      assert_receive {:signal, "enrollment.completed", ^payload}, 500
      assert_receive {:signal, "enrollment.completed", ^payload}, 500

      # 处理屏障：第三个真实信号（另一报名的 completed）——其通知任务出现即
      # 证明订阅方已顺序处理完之前的两条重复投递（单总线进程 FIFO 投递）。
      barrier_learner = Fixtures.register_user("signal-dup-barrier")
      insert_identity(barrier_learner.id, "signal-dup-barrier-openid")

      {:ok, barrier_enrollment} = create_enrollment(event, barrier_learner)

      assert_enqueued(
        [
          worker: NotificationWorker,
          args: %{
            "template_key" => "enrollment_completed",
            "enrollment_id" => barrier_enrollment.id
          }
        ],
        2_000
      )

      # 最终状态：两条重复投递只产生一条通知任务 + 一行幂等记录
      assert [%{args: %{"idempotency_key" => key}}] =
               all_enqueued(
                 worker: NotificationWorker,
                 args: %{
                   "template_key" => "enrollment_completed",
                   "enrollment_id" => enrollment.id
                 }
               )

      assert key == "enrollment.completed:" <> enrollment.id
      assert claim_rows("enrollment.completed", key) == 1
    end

    test "同键信号重复投喂：第二次返回 :duplicate 且不重复入队" do
      admin = Fixtures.platform_admin("signal-direct-admin")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("signal-direct-learner")

      event = EventFixtures.create_event(workspace, admin)
      insert_identity(learner.id, "signal-direct-learner-openid")

      {:ok, enrollment} = create_enrollment(event, learner)

      key = "enrollment.completed:" <> enrollment.id
      payload = completed_payload(enrollment, event)

      # 等原始 completed 信号消费完成（任务入队 = 订阅方已处理完该次投递），
      # 再清除其效果（测试布置），让两次直接投喂从零开始——避免与在途异步
      # 投递竞争。
      assert_enqueued(
        [
          worker: NotificationWorker,
          args: %{"template_key" => "enrollment_completed", "enrollment_id" => enrollment.id}
        ],
        2_000
      )

      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        "DELETE FROM signal_idempotency WHERE signal_type = 'enrollment.completed' AND idempotency_key = $1",
        [key]
      )

      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        "DELETE FROM oban_jobs WHERE args->>'idempotency_key' = $1",
        [key]
      )

      signal = %{type: "enrollment.completed", data: payload}

      assert :ok = NotificationSubscriber.handle_signal(signal)
      assert :duplicate = NotificationSubscriber.handle_signal(signal)

      assert [%{args: %{"idempotency_key" => ^key}}] =
               all_enqueued(
                 worker: NotificationWorker,
                 args: %{
                   "template_key" => "enrollment_completed",
                   "enrollment_id" => enrollment.id
                 }
               )

      assert claim_rows("enrollment.completed", key) == 1
    end
  end

  defp create_enrollment(event, user) do
    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, %{event_id: event.id, user_id: user.id})
    |> Ash.create(tenant: event.workspace_id, actor: user)
  end

  defp confirm(enrollment, actor) do
    enrollment
    |> Ash.Changeset.for_update(:confirm_enrollment, %{})
    |> Ash.update(tenant: enrollment.workspace_id, actor: actor)
  end

  # 与生产者 after_transaction 发布的 payload 形状一致（open 策略）
  defp completed_payload(enrollment, event) do
    %{
      "enrollment_id" => enrollment.id,
      "workspace_id" => enrollment.workspace_id,
      "user_id" => enrollment.user_id,
      "status" => "confirmed",
      "event_id" => event.id,
      "course_id" => nil,
      "enrollment_policy" => "open",
      "idempotency_key" => "enrollment.completed:" <> enrollment.id
    }
  end

  defp subscribe_spy do
    parent = self()

    assert {:ok, _sub_id} =
             JidoAdapter.subscribe(
               "enrollment.completed",
               fn signal -> send(parent, {:signal, signal.type, signal.data}) end,
               nil
             )
  end

  defp insert_identity(user_id, uid) do
    Cgc2046.Repo.query!(
      """
      INSERT INTO user_identities (id, provider, uid, user_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), 'wechat', $1, $2, NOW(), NOW())
      """,
      [uid, Ecto.UUID.dump!(user_id)]
    )
  end

  defp claim_rows(signal_type, key) do
    SignalIdempotency
    |> Ash.Query.filter(signal_type == ^signal_type and idempotency_key == ^key)
    |> Ash.read!(authorize?: false)
    |> length()
  end
end
