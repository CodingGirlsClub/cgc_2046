defmodule Cgc2046.AsyncSignalTest do
  @moduledoc """
  E-2 #47 验收：异步衍生 Signal 订阅方（Notifications.Subscriber）端到端测试。

  分层（与 repo 既有纪律对齐——curriculum/reaper_test 直接调 deliver/2，
  「信号总线异步投递在 POC 已验证」）：

  1. **真实总线异步投递**：Enrollment after_action 事务内入队 SignalPublishWorker
     job（plan 2026-08-14-003 Q6）→ 测试同步 perform_job 驱动真实 worker 发布 →
     内存信号总线 → 测试进程的订阅转发进程（JidoAdapter.subscribe 的 forwarder）
     → 测试进程邮箱。转发只收发消息、不做 DB（跨进程零竞争）。
  2. **真实订阅方处理**：测试进程对投递到的信号执行同一个
     `SignalSubscriber.deliver/2`（与生产 forwarder 同码：claim-first 幂等 +
     Oban 入队全路径）。测试进程是 sandbox owner，DB 副作用确定性执行，不受
     应用级进程与共享连接竞争影响（CI 慢机上曾出现 DBConnection 连接交接取消
     在途查询、应用订阅方长时间静默导致轮询断言超时——本设计从结构上消除该
     竞争）。

  应用级订阅方（Application 监督树中的实例）在本测试期间被 terminate/restart，
  避免其并发消费同一信号造成 claim 竞争（骨架统一 claim 键后两方仍争同键，
  该搏斗无法安全移除——plan「若可行」判定为不可行）；订阅接线由 patterns/0
  断言 + 全量套件中订阅方的实际消费行为覆盖。

  至少一次语义：生产者事务内发布的信号若未在窗口内投递（:timeout），按同一
  payload 真实重投再等（与 SignalPublishWorker 重试同构的恢复路径）。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Notifications.Subscriber
  alias Cgc2046.Workflows.{JidoAdapter, SignalIdempotency, SignalSubscriber}
  alias Cgc2046.Notifications.NotificationWorker
  alias Cgc2046.Workflows.SignalPublishWorker

  require Ash.Query

  @max_redeliveries 3

  setup do
    # 停掉应用级订阅方：本测试经自己的订阅转发进程接收同一信号并同步驱动
    # deliver/2（sandbox owner），避免两个消费者对同一 claim 的竞争。
    :ok = Supervisor.terminate_child(Cgc2046.Supervisor, Subscriber)

    on_exit(fn ->
      {:ok, _pid} = Supervisor.restart_child(Cgc2046.Supervisor, Subscriber)
    end)

    test_pid = self()

    for pattern <- Subscriber.patterns() do
      assert {:ok, _sub_id, _monitor_ref, _forwarder_pid} =
               JidoAdapter.subscribe(pattern, fn type, data ->
                 send(test_pid, {:bus_signal, %{type: type, data: data}})
               end)
    end

    :ok
  end

  test "订阅接线：submitted/completed 已注册（其余模式由全量套件消费行为覆盖）" do
    patterns = Subscriber.patterns()
    assert "enrollment.submitted" in patterns
    assert "enrollment.completed" in patterns
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

      # 生产侧：信号已随报名事务入队 SignalPublishWorker job；同步执行驱动真实发布
      perform_enqueued_signal("enrollment.submitted", enrollment.id)

      # 异步最终一致：等真实总线投递 submitted 信号并执行真实订阅方处理，
      # 再断言 Owner/Admin 待审批通知任务。
      handle_producer_signal(
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

      perform_enqueued_signal("enrollment.completed", enrollment.id)

      handle_producer_signal(
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

      perform_enqueued_signal("enrollment.submitted", enrollment.id)
      perform_enqueued_signal("enrollment.completed", enrollment.id)

      # open 策略：submitted（跳过，无待审批语义）与 completed 均已处理
      handle_producer_signal(
        "enrollment.submitted",
        enrollment.id,
        submitted_payload(enrollment, event)
      )

      handle_producer_signal(
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

      perform_enqueued_signal("enrollment.completed", enrollment.id)

      # 原始 completed 信号消费完成（claim + 任务入队）
      handle_producer_signal(
        "enrollment.completed",
        enrollment.id,
        completed_payload(enrollment, event)
      )

      payload = completed_payload(enrollment, event)

      # 真实重复投递两条（payload 与生产者一致，含同一 idempotency_key）
      assert :ok = JidoAdapter.publish("enrollment.completed", payload)
      assert :ok = JidoAdapter.publish("enrollment.completed", payload)

      # 订阅方逐条执行真实处理并返回 :duplicate（claim-first 拦截的直接证据）
      assert :duplicate = handle_delivered_signal("enrollment.completed", enrollment.id)
      assert :duplicate = handle_delivered_signal("enrollment.completed", enrollment.id)

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
      assert claim_rows("enrollment.completed", claim_key(enrollment.id)) == 1
    end

    test "同键信号重复投喂：第二次返回 :duplicate 且不重复入队" do
      admin = Fixtures.platform_admin("signal-direct-admin")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("signal-direct-learner")

      event = EventFixtures.create_event(workspace, admin)
      insert_identity(learner.id, "signal-direct-learner-openid")

      {:ok, enrollment} = create_enrollment(event, learner)

      perform_enqueued_signal("enrollment.completed", enrollment.id)

      # 等原始 completed 信号消费完成（任务入队 = 已处理完该次投递），
      # 再清除其效果（测试布置），让两次直接投喂从零开始——避免与在途投递竞争。
      handle_producer_signal(
        "enrollment.completed",
        enrollment.id,
        completed_payload(enrollment, event)
      )

      key = "enrollment.completed:" <> enrollment.id
      payload = completed_payload(enrollment, event)

      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        "DELETE FROM signal_idempotency WHERE signal_type = 'enrollment.completed' AND idempotency_key = $1",
        [claim_key(enrollment.id)]
      )

      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        "DELETE FROM oban_jobs WHERE args->>'idempotency_key' = $1",
        [key]
      )

      signal = %{type: "enrollment.completed", data: payload}

      assert :ok = SignalSubscriber.deliver(Subscriber, signal)
      assert :duplicate = SignalSubscriber.deliver(Subscriber, signal)

      assert [%{args: %{"idempotency_key" => ^key}}] =
               all_enqueued(
                 worker: NotificationWorker,
                 args: %{
                   "template_key" => "enrollment_completed",
                   "enrollment_id" => enrollment.id
                 }
               )

      assert claim_rows("enrollment.completed", claim_key(enrollment.id)) == 1
    end
  end

  # 生产侧信号经 SignalPublishWorker 事务内 outbox 入队（plan 2026-08-14-003 Q6）；
  # manual 测试模式下同步执行该 job，驱动 worker → 真实总线投递全链路。
  # 锚定 enrollment_id——套件内并发类测试真实提交的残留 job 不影响匹配。
  defp perform_enqueued_signal(signal_type, enrollment_id) do
    [job] =
      [worker: SignalPublishWorker]
      |> all_enqueued()
      |> Enum.filter(
        &(&1.args["signal_type"] == signal_type &&
            get_in(&1.args, ["data", "enrollment_id"]) == enrollment_id)
      )

    perform_job(SignalPublishWorker, job.args)
  end

  # 生产者事务内入队、经 worker 发布的信号：等真实总线投递 → 执行真实订阅方处理（结果应为 :ok）；
  # 窗口内未投递（:timeout）→ 按同一 payload 真实重投再等（至少一次语义的恢复
  # 路径，同 SignalPublishWorker 重试）。
  defp handle_producer_signal(
         signal_type,
         enrollment_id,
         payload,
         redeliveries \\ @max_redeliveries
       ) do
    case handle_delivered_signal(signal_type, enrollment_id) do
      :ok ->
        :ok

      :timeout when redeliveries > 0 ->
        assert :ok = JidoAdapter.publish(signal_type, payload)

        handle_producer_signal(signal_type, enrollment_id, payload, redeliveries - 1)

      result ->
        flunk("signal " <> signal_type <> " not handled: " <> inspect(result))
    end
  end

  # 从测试进程邮箱取一条该 (type, enrollment_id) 的真实总线投递并同步驱动订阅方
  # （deliver/2 与生产 forwarder 同码）。
  defp handle_delivered_signal(signal_type, enrollment_id, timeout \\ 10_000) do
    receive do
      {:bus_signal, %{type: ^signal_type, data: %{"enrollment_id" => ^enrollment_id}} = signal} ->
        SignalSubscriber.deliver(Subscriber, signal)
    after
      timeout -> :timeout
    end
  end

  # 骨架消费键（plan Q12）：生产者键 <> ":" <> 消费者短名。
  defp claim_key(enrollment_id),
    do: "enrollment.completed:" <> enrollment_id <> ":subscriber"

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

  # 与生产者 SignalEmitter 入队的 payload 形状一致（idempotency_key / workspace_id
  # 由 emitter 注入，plan 2026-08-14-003 Q12）
  defp submitted_payload(enrollment, event) do
    %{
      "enrollment_id" => enrollment.id,
      "workspace_id" => enrollment.workspace_id,
      "user_id" => enrollment.user_id,
      "status" => to_string(enrollment.status),
      "event_id" => event.id,
      "course_id" => nil,
      "enrollment_policy" => "request",
      "idempotency_key" => "enrollment.submitted:" <> enrollment.id
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
