defmodule Cgc2046.AsyncSignalTest do
  @moduledoc """
  E-2 #47 验收：异步衍生 Signal 订阅方（NotificationSubscriber）端到端测试。

  全栈异步路径：Enrollment after_transaction 发布 → 内存信号总线 →
  NotificationSubscriber 订阅回调（独立进程）→ SignalIdempotency.claim →
  Oban NotificationWorker 入队。

  确定性同步：订阅方在每条信号处理完成后发射
  `[:cgc_2046, :notification_subscriber, :handled]` telemetry 事件
  （metadata: signal_type / enrollment_id / result）。测试收到事件后再断言
  DB 状态——等待期间测试进程不发 DB 查询，订阅进程独占共享 sandbox 连接，
  消除 DB 轮询竞争与 CI 慢机上的连接交接取消窗口。

  至少一次语义：生产者事务内发布的信号可能撞上订阅进程的连接竞争窗口而被
  丢弃（claim 未登记、无副作用）；测试按同一 payload 真实重投再等（与
  SignalPublishWorker 重试同构的恢复路径），既复现至少一次投递的现实语义，
  也保证断言不被瞬时连接竞争打挂。
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

  @handled_event [:cgc_2046, :notification_subscriber, :handled]
  @max_redeliveries 3

  setup do
    test_pid = self()
    handler_id = "async-signal-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        @handled_event,
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:signal_handled, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

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

      # 异步最终一致：等订阅方处理完 submitted 信号，再断言 Owner/Admin 待审批通知任务
      wait_producer_signal(
        "enrollment.submitted",
        enrollment.id,
        submitted_payload(enrollment, event)
      )

      assert [%{args: submitted_args}] =
               all_enqueued(
                 worker: NotificationWorker,
                 args: %{
                   "template_key" => "enrollment_submitted",
                   "enrollment_id" => enrollment.id
                 }
               )

      assert submitted_args["user_id"] == admin.id
      assert submitted_args["data"]["title"] == event.title
      assert submitted_args["idempotency_key"] == "enrollment.submitted:" <> enrollment.id

      # request 提交尚无 completed 信号：报名学员没有报名成功任务
      assert [] =
               all_enqueued(
                 worker: NotificationWorker,
                 args: %{
                   "template_key" => "enrollment_completed",
                   "enrollment_id" => enrollment.id
                 }
               )

      # 审批通过 → completed → 学员本人报名成功任务（含活动标题）
      {:ok, _} = confirm(enrollment, admin)

      wait_producer_signal(
        "enrollment.completed",
        enrollment.id,
        completed_payload(enrollment, event)
      )

      assert [%{args: completed_args}] =
               all_enqueued(
                 worker: NotificationWorker,
                 args: %{
                   "template_key" => "enrollment_completed",
                   "enrollment_id" => enrollment.id
                 }
               )

      assert completed_args["user_id"] == learner.id
      assert completed_args["data"]["title"] == event.title
      assert completed_args["idempotency_key"] == "enrollment.completed:" <> enrollment.id
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

      # open 策略：submitted（跳过，无待审批语义）与 completed 均已处理完
      wait_producer_signal(
        "enrollment.submitted",
        enrollment.id,
        submitted_payload(enrollment, event)
      )

      wait_producer_signal(
        "enrollment.completed",
        enrollment.id,
        completed_payload(enrollment, event)
      )

      assert [%{args: args}] =
               all_enqueued(
                 worker: NotificationWorker,
                 args: %{
                   "template_key" => "enrollment_completed",
                   "enrollment_id" => enrollment.id
                 }
               )

      assert args["user_id"] == learner.id
      assert args["data"]["title"] == event.title

      # submitted 信号确实发布过（生产者对全策略发布），但无待审批语义 → 不通知 Owner/Admin
      assert [] = all_enqueued(args: %{"template_key" => "enrollment_submitted"})
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

      # 原始 completed 信号消费完成
      wait_producer_signal(
        "enrollment.completed",
        enrollment.id,
        completed_payload(enrollment, event)
      )

      payload = completed_payload(enrollment, event)

      # 真实重复投递两条（payload 与生产者一致，含同一 idempotency_key）
      assert :ok = JidoAdapter.publish("enrollment.completed", payload, workspace.id)
      assert :ok = JidoAdapter.publish("enrollment.completed", payload, workspace.id)

      # 订阅方逐条报告 :duplicate（claim-first 拦截的直接证据）
      assert :duplicate = wait_handled("enrollment.completed", enrollment.id)
      assert :duplicate = wait_handled("enrollment.completed", enrollment.id)

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

      # 等原始 completed 信号消费完成（任务入队 = 订阅方已处理完该次投递），
      # 再清除其效果（测试布置），让两次直接投喂从零开始——避免与在途异步
      # 投递竞争。
      wait_producer_signal(
        "enrollment.completed",
        enrollment.id,
        completed_payload(enrollment, event)
      )

      key = "enrollment.completed:" <> enrollment.id
      payload = completed_payload(enrollment, event)

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

  # 生产者事务内发布的信号：等待订阅方报告处理结果；:timeout/:error（连接竞争
  # 窗口导致的投递丢弃，claim 未登记、无副作用）→ 按同一 payload 真实重投再等
  # （至少一次语义的恢复路径，同 SignalPublishWorker 重试）。
  defp wait_producer_signal(
         signal_type,
         enrollment_id,
         payload,
         redeliveries \\ @max_redeliveries
       ) do
    case wait_handled(signal_type, enrollment_id) do
      :ok ->
        :ok

      result when result in [:timeout, :error] and redeliveries > 0 ->
        assert :ok =
                 JidoAdapter.publish(signal_type, payload, Map.get(payload, "workspace_id"))

        wait_producer_signal(signal_type, enrollment_id, payload, redeliveries - 1)

      result ->
        flunk("signal #{signal_type} not handled: #{inspect(result)}")
    end
  end

  # 等订阅方报告该信号处理完成（telemetry 事件经 handler 投递到测试进程）。
  # 等待期间测试进程不发 DB 查询，订阅进程独占共享 sandbox 连接。
  defp wait_handled(signal_type, enrollment_id, timeout \\ 10_000) do
    receive do
      {:signal_handled,
       %{signal_type: ^signal_type, enrollment_id: ^enrollment_id, result: result}} ->
        result
    after
      timeout -> :timeout
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

  # 与生产者 after_transaction 发布的 payload 形状一致
  defp submitted_payload(enrollment, event) do
    %{
      "enrollment_id" => enrollment.id,
      "workspace_id" => enrollment.workspace_id,
      "user_id" => enrollment.user_id,
      "status" => to_string(enrollment.status),
      "event_id" => event.id,
      "course_id" => nil,
      "enrollment_policy" => "request"
    }
  end

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
