defmodule Cgc2046.NotificationServiceTest do
  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.Miniprogram.Client
  alias Cgc2046.NotificationConsent
  alias Cgc2046.NotificationService
  alias Cgc2046.NotificationSubscriber
  alias Cgc2046.AccountsFixtures, as: Fixtures

  setup do
    test_pid = self()

    Req.Test.stub(Cgc2046.MiniprogramClientStub, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, conn.host, conn.request_path} do
        {"GET", "api.weixin.qq.com", "/cgi-bin/token"} ->
          Req.Test.json(conn, %{"access_token" => "wx-token"})

        {"POST", "api.weixin.qq.com", "/cgi-bin/message/subscribe/send"} ->
          send(test_pid, {:notification, :wechat, body!(conn)})
          Req.Test.json(conn, %{"errcode" => 0})

        {"POST", "open.douyin.com", "/oauth/client_token/"} ->
          Req.Test.json(conn, %{"data" => %{"access_token" => "tt-token"}})

        {"POST", "open.douyin.com", "/api/notification/v2/subscription/notify_user/"} ->
          send(test_pid, {:notification, :tt, body!(conn)})
          Req.Test.json(conn, %{"err_no" => 0, "err_msg" => "", "log_id" => "test"})

        {"GET", "miniapp.xiaohongshu.com", "/api/rmp/token"} ->
          Req.Test.json(conn, %{"code" => 0, "data" => %{"access_token" => "xhs-token"}})

        {"POST", "miniapp.xiaohongshu.com", "/api/rmp/subscribe/send"} ->
          send(test_pid, {:notification, :xhs, body!(conn)})
          Req.Test.json(conn, %{"code" => 0, "data" => %{}})

        other ->
          raise "unexpected notification request: #{inspect(other)}"
      end
    end)

    :ok
  end

  test "一次授权增加一份配额，发送成功才原子消费且不会减成负数" do
    user = Fixtures.register_user("notification-consent")
    insert_identity(user.id, :wechat, "wx-openid")

    assert {:ok, 1} = NotificationConsent.grant(user.id, :wechat, "approval_result")
    assert {:ok, 2} = NotificationConsent.grant(user.id, :wechat, "approval_result")

    assert :ok =
             NotificationService.send_to_user(user.id, :wechat, "approval_result", %{
               "thing1" => %{"value" => "报名已通过"}
             })

    assert_receive {:notification, :wechat, %{"touser" => "wx-openid"}}
    assert {:ok, 1} = NotificationConsent.remaining(user.id, :wechat, "approval_result")

    assert :ok = NotificationService.send_to_user(user.id, :wechat, "approval_result", %{})

    assert {:error, :consent_exhausted} =
             NotificationService.send_to_user(user.id, :wechat, "approval_result", %{})

    assert {:ok, 0} = NotificationConsent.remaining(user.id, :wechat, "approval_result")
  end

  test "三平台 adapter 使用 registry 模板并归一成功信封" do
    for platform <- [:wechat, :tt, :xhs] do
      assert :ok =
               Client.send_notification(
                 platform,
                 "openid-#{platform}",
                 "template-#{platform}",
                 %{"status" => "confirmed"}
               )

      assert_receive {:notification, ^platform, body}
      assert inspect(body) =~ "template-#{platform}"
    end
  end

  test "同一用户的两个不同 Enrollment 审批结果分别入队" do
    user = Fixtures.register_user("notification-signal")
    insert_identity(user.id, :wechat, "signal-openid")
    first_enrollment_id = Ecto.UUID.generate()
    second_enrollment_id = Ecto.UUID.generate()

    assert :ok =
             NotificationSubscriber.enqueue_approval_result(%{
               "user_id" => user.id,
               "status" => "confirmed",
               "enrollment_id" => first_enrollment_id
             })

    assert :ok =
             NotificationSubscriber.enqueue_approval_result(%{
               "user_id" => user.id,
               "status" => "confirmed",
               "enrollment_id" => second_enrollment_id
             })

    jobs = all_enqueued(worker: Cgc2046.Workers.NotificationWorker)
    assert length(jobs) == 2

    assert Enum.map(jobs, & &1.args["enrollment_id"]) |> Enum.sort() ==
             Enum.sort([first_enrollment_id, second_enrollment_id])

    refute_receive {:notification, _, _}
  end

  test "同用户同平台两个身份的提醒各自入队、不被 args 去重折叠（#3）" do
    user = Fixtures.register_user("notification-multi-identity")
    insert_identity(user.id, :wechat, "wx-openid-1")
    insert_identity(user.id, :wechat, "wx-openid-2")
    enrollment_id = Ecto.UUID.generate()
    deadline = DateTime.add(DateTime.utc_now(), 24, :hour)

    assert :ok = NotificationSubscriber.enqueue_reminder(user.id, enrollment_id, deadline)

    jobs = all_enqueued(worker: Cgc2046.Workers.NotificationWorker)
    assert length(jobs) == 2

    assert Enum.map(jobs, & &1.args["identity_uid"]) |> Enum.sort() ==
             ["wx-openid-1", "wx-openid-2"]
  end

  test "send_to_identity 按指定身份精确投递（#3）" do
    user = Fixtures.register_user("notification-identity-target")
    insert_identity(user.id, :wechat, "wx-openid-1")
    insert_identity(user.id, :wechat, "wx-openid-2")

    {:ok, _} = NotificationConsent.grant(user.id, :wechat, "approval_result")

    assert :ok =
             NotificationService.send_to_identity(
               user.id,
               :wechat,
               "wx-openid-2",
               "approval_result",
               %{"thing1" => %{"value" => "报名已通过"}}
             )

    assert_receive {:notification, :wechat, %{"touser" => "wx-openid-2"}}
  end

  defp insert_identity(user_id, platform, uid) do
    Cgc2046.Repo.query!(
      """
      INSERT INTO user_identities (id, provider, uid, user_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $2, $3, NOW(), NOW())
      """,
      [to_string(platform), uid, Ecto.UUID.dump!(user_id)]
    )
  end

  defp body!(conn) do
    {:ok, raw, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(raw)
  end
end
