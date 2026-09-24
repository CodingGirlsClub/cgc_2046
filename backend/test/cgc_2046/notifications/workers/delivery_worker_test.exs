defmodule Cgc2046.Notifications.Workers.DeliveryWorkerTest do
  @moduledoc """
  #556：DeliveryWorker 末拍终态化——pending_reason 类失败在 job 耗尽后
  不再滞留 pending（行落 :failed 带原因，规15 Finding 出报表）。
  #847：发送前过期重查（Staleness 共用解释器）——stale 行终态化
  :failed + last_error ":stale"，不投递不重试；与 NotificationWorker
  对同一 args 的过期判定一致。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Notifications.{Consent, Delivery, NotificationDelivery}
  alias Cgc2046.Notifications.{NotificationWorker, Workers.DeliveryWorker}

  require Ash.Query

  defp enqueue_delivery(user_id) do
    key = "delivery-worker-test-#{System.unique_integer([:positive])}"

    :ok =
      Delivery.enqueue(
        {user_id, [%{provider: :wechat, uid: "openid-#{key}"}]},
        "approval_result",
        %{},
        %{"idempotency_key" => key}
      )

    [row] =
      NotificationDelivery
      |> Ash.Query.filter(user_id == ^user_id)
      |> Ash.read!(authorize?: false)

    row
  end

  test "末拍（attempt = max_attempts）pending_reason → 终态 failed，last_error 带原因" do
    user = Fixtures.register_user("dw-final")
    row = enqueue_delivery(user.id)

    # consent_exhausted 是 pending_reason（未订阅授权）——非末拍只重试不落终态；
    # 末拍（第 5 次，max_attempts=5）终态化
    assert {:error, :consent_exhausted} =
             perform_job(DeliveryWorker, %{"delivery_id" => row.id}, attempt: 5)

    reloaded = Ash.get!(NotificationDelivery, row.id, authorize?: false)
    assert reloaded.status == :failed
    assert reloaded.last_error =~ "consent_exhausted"
    assert reloaded.attempts == 1
  end

  test "非末拍 pending_reason → 仍 pending（重试语义不变）" do
    user = Fixtures.register_user("dw-retry")
    row = enqueue_delivery(user.id)

    assert {:error, :consent_exhausted} =
             perform_job(DeliveryWorker, %{"delivery_id" => row.id}, attempt: 2)

    reloaded = Ash.get!(NotificationDelivery, row.id, authorize?: false)
    assert reloaded.status == :pending
    assert reloaded.attempts == 0
  end

  test "已 sent 行幂等 no-op（不重复投递、不落终态）" do
    user = Fixtures.register_user("dw-sent")
    row = enqueue_delivery(user.id)

    {:ok, sent} =
      row
      |> Ash.Changeset.for_update(:mark_sent, %{}, authorize?: false)
      |> Ash.update()

    assert :ok = perform_job(DeliveryWorker, %{"delivery_id" => sent.id}, attempt: 5)
    assert Ash.get!(NotificationDelivery, row.id, authorize?: false).status == :sent
  end

  # --- #847 发送前过期重查（Staleness 共用解释器） --------------------------------

  # 投递路径 stub wechat 平台（notification_worker_test 同款：SDK client +
  # Tesla.Mock；stale 路径不触达 HTTP，mock 兜底防误发真实请求）。
  setup do
    test_pid = self()

    Tesla.Mock.mock(fn
      %{method: :post, url: "https://api.weixin.qq.com/cgi-bin/message/subscribe/send" <> _} = env ->
        send(test_pid, {:notification, :wechat, Jason.decode!(env.body)})
        Tesla.Mock.json(%{"errcode" => 0})
    end)

    Req.Test.stub(Cgc2046.MiniprogramClientStub, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, conn.host, conn.request_path} do
        other ->
          raise "unexpected notification request: #{inspect(other)}"
      end
    end)

    :ok
  end

  defp deliveries_for(user_id) do
    NotificationDelivery
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(authorize?: false)
  end

  defp enqueue_key(user_id, uid, template_key, data) do
    key = "delivery-worker-test-#{System.unique_integer([:positive])}"
    # uid nil = 零身份入队（落哨兵行，Q5）
    identities = if is_nil(uid), do: [], else: [%{provider: :wechat, uid: uid}]

    :ok =
      Delivery.enqueue(
        {user_id, identities},
        template_key,
        data,
        %{"idempotency_key" => key}
      )

    # 同一测试内可能多次 enqueue（如两路径一致性），取最新落的那行
    deliveries_for(user_id) |> Enum.max_by(& &1.inserted_at, DateTime)
  end

  # approval_reminder × enrollment_id 面（notification_worker_test 同款搭建）。
  defp enrollment_setup do
    owner = Fixtures.platform_admin("dws-enroll-admin")
    workspace = Fixtures.create_workspace(owner)
    learner = Fixtures.register_user("dws-enroll-learner")
    event = EventFixtures.create_event(workspace, owner, %{enrollment_policy: :request})

    enrollment =
      Enrollment
      |> Ash.Changeset.for_create(
        :create_enrollment,
        %{
          event_id: event.id,
          user_id: learner.id,
          approval_deadline: DateTime.add(DateTime.utc_now(), 24, :hour)
        },
        tenant: workspace.id,
        actor: learner
      )
      |> Ash.create!(tenant: workspace.id, actor: learner)

    insert_identity(owner.id, "dws-enroll-owner-openid")
    {:ok, _} = Consent.grant(owner.id, :wechat, "approval_reminder")
    %{owner: owner, enrollment: enrollment}
  end

  defp expire_enrollment!(enrollment) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE enrollments SET status = 'expired' WHERE id = $1",
        [Ecto.UUID.dump!(enrollment.id)]
      )

    :ok
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

  defp reminder_args(owner, enrollment) do
    %{
      "user_id" => owner.id,
      "identity_uid" => "dws-enroll-owner-openid",
      "platform" => "wechat",
      "template_key" => "approval_reminder",
      "data" => %{
        "enrollment_id" => enrollment.id,
        "approval_deadline" => DateTime.to_iso8601(enrollment.approval_deadline)
      }
    }
  end

  defp data_for(enrollment) do
    %{
      "enrollment_id" => enrollment.id,
      "approval_deadline" => DateTime.to_iso8601(enrollment.approval_deadline)
    }
  end

  describe "#847 发送前过期重查" do
    test "stale 行 → 不投递：终态 :failed、last_error \":stale\"、job :ok、consent 未消耗" do
      %{owner: owner, enrollment: enrollment} = enrollment_setup()
      :ok = expire_enrollment!(enrollment)

      row =
        enqueue_key(
          owner.id,
          "dws-enroll-owner-openid",
          "approval_reminder",
          data_for(enrollment)
        )

      assert :ok = perform_job(DeliveryWorker, %{"delivery_id" => row.id}, attempt: 1)

      reloaded = Ash.get!(NotificationDelivery, row.id, authorize?: false)
      assert reloaded.status == :failed
      assert reloaded.last_error == ":stale"
      assert reloaded.attempts == 1
      refute_receive {:notification, :wechat, _}
      assert {:ok, 1} = Consent.remaining(owner.id, :wechat, "approval_reminder")
    end

    test "非 stale 键（走 Delivery 的 4 键之一）不触发重查，照常投递 → 行 sent" do
      user = Fixtures.register_user("dws-schedule")
      insert_identity(user.id, "dws-schedule-openid")
      {:ok, _} = Consent.grant(user.id, :wechat, "event_schedule_changed")

      # event_id 指向不存在的实体：若有任何 stale 重查都会被拦下，照发即证明放行
      row =
        enqueue_key(user.id, "dws-schedule-openid", "event_schedule_changed", %{
          "event_id" => "00000000-0000-0000-0000-000000000000",
          "title" => "t",
          "starts_at" => "2026-10-01T10:00:00Z",
          "venue" => "v"
        })

      assert :ok = perform_job(DeliveryWorker, %{"delivery_id" => row.id}, attempt: 1)

      assert %{status: :sent} = Ash.get!(NotificationDelivery, row.id, authorize?: false)
      assert_receive {:notification, :wechat, _}
      assert {:ok, 0} = Consent.remaining(user.id, :wechat, "event_schedule_changed")
    end

    test "两路径一致：同一 args 下 NotificationWorker 与 DeliveryWorker 过期判定同源同果" do
      %{owner: owner, enrollment: enrollment} = enrollment_setup()
      :ok = expire_enrollment!(enrollment)

      # stale：Fanout 路径（NotificationWorker）静默跳过；耐久路径（DeliveryWorker）
      # 同样不投递，行落 :failed ":stale"——两条路径同一解释器、同一结论
      assert :ok = perform_job(NotificationWorker, reminder_args(owner, enrollment))
      refute_receive {:notification, :wechat, _}

      row =
        enqueue_key(
          owner.id,
          "dws-enroll-owner-openid",
          "approval_reminder",
          data_for(enrollment)
        )

      assert :ok = perform_job(DeliveryWorker, %{"delivery_id" => row.id}, attempt: 1)

      assert %{status: :failed, last_error: ":stale"} =
               Ash.get!(NotificationDelivery, row.id, authorize?: false)

      refute_receive {:notification, :wechat, _}

      # 非 stale（拨回 pending）：两路径都投递——判定同源的双向证明
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE enrollments SET status = 'pending' WHERE id = $1",
          [Ecto.UUID.dump!(enrollment.id)]
        )

      {:ok, _} = Consent.grant(owner.id, :wechat, "approval_reminder")
      {:ok, _} = Consent.grant(owner.id, :wechat, "approval_reminder")

      assert :ok = perform_job(NotificationWorker, reminder_args(owner, enrollment))
      assert_receive {:notification, :wechat, _}

      row2 =
        enqueue_key(
          owner.id,
          "dws-enroll-owner-openid",
          "approval_reminder",
          data_for(enrollment)
        )

      assert :ok = perform_job(DeliveryWorker, %{"delivery_id" => row2.id}, attempt: 1)
      assert %{status: :sent} = Ash.get!(NotificationDelivery, row2.id, authorize?: false)
      assert_receive {:notification, :wechat, _}
    end
  end

  describe "#847 零身份语义（Q5：哨兵行可观测、可对账）" do
    test "哨兵行 + 用户其后绑定身份 → 重解析 assign 后投递，终态 sent" do
      user = Fixtures.register_user("dws-zero-late")
      {:ok, _} = Consent.grant(user.id, :wechat, "approval_result")

      # 入队时零身份：落哨兵行（platform/identity_uid 均为 nil）
      row = enqueue_key(user.id, nil, "approval_result", %{"status" => "confirmed"})
      assert is_nil(row.identity_uid)
      assert is_nil(row.platform)

      # 其后用户绑定了平台身份——worker 发送前重解析并 assign
      insert_identity(user.id, "dws-zero-late-openid")

      assert :ok = perform_job(DeliveryWorker, %{"delivery_id" => row.id}, attempt: 1)

      reloaded = Ash.get!(NotificationDelivery, row.id, authorize?: false)
      assert reloaded.status == :sent
      assert reloaded.platform == "wechat"
      assert reloaded.identity_uid == "dws-zero-late-openid"
      assert_receive {:notification, :wechat, _}
      assert {:ok, 0} = Consent.remaining(user.id, :wechat, "approval_result")
    end

    test "哨兵行 + 始终无身份 → identity_not_found 重试至末拍终态化 :failed（rule 15 可查）" do
      user = Fixtures.register_user("dws-zero-none")

      row = enqueue_key(user.id, nil, "approval_result", %{"status" => "confirmed"})

      # 非末拍：pending_reason 类失败只重试，行保持 pending（可观测未丢失）
      assert {:error, :identity_not_found} =
               perform_job(DeliveryWorker, %{"delivery_id" => row.id}, attempt: 1)

      assert %{status: :pending} = Ash.get!(NotificationDelivery, row.id, authorize?: false)

      # 末拍：终态化 :failed 带 last_error——对账面（rule 15 Finding）可见
      assert {:error, :identity_not_found} =
               perform_job(DeliveryWorker, %{"delivery_id" => row.id}, attempt: 5)

      reloaded = Ash.get!(NotificationDelivery, row.id, authorize?: false)
      assert reloaded.status == :failed
      assert reloaded.last_error =~ "identity_not_found"
      refute_receive {:notification, :wechat, _}
    end
  end
end
