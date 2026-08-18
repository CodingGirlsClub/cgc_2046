defmodule Cgc2046.NotificationServiceTest do
  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.Miniprogram.Client
  alias Cgc2046.NotificationConsent
  alias Cgc2046.NotificationFanout
  alias Cgc2046.NotificationService
  alias Cgc2046.AccountsFixtures, as: Fixtures

  setup do
    test_pid = self()

    Req.Test.stub(Cgc2046.MiniprogramClientStub, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, conn.host, conn.request_path} do
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

    # wechat 分支已迁 SDK（token 由 SDK ETS 管理）——请求层走宿主 WechatRequester
    # 的 Tesla.Mock adapter。BaseUrl middleware 在 adapter 前，mock 收到的是全 URL。
    # mock fun 内回传请求体后返回；token 读 Cache 得 nil 只影响 query，不出网。
    Tesla.Mock.mock(fn
      %{method: :post, url: "https://api.weixin.qq.com/cgi-bin/message/subscribe/send" <> _} = env ->
        send(test_pid, {:notification, :wechat, Jason.decode!(env.body)})
        Tesla.Mock.json(%{"errcode" => 0})
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
    expected_pages = %{
      wechat: "pages/profile/index",
      tt: "pages/my-enrollments/index",
      xhs: "pages/my-enrollments/index"
    }

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
      # 落页契约：页面必须存在于 miniprogram/src/app.config.ts（本计划修正项）
      assert body["page"] == expected_pages[platform]
    end
  end

  test "wechat 43101 拒收：errcode 保真出栈且 consent 原子回补" do
    Tesla.Mock.mock(fn
      %{method: :post, url: "https://api.weixin.qq.com/cgi-bin/message/subscribe/send" <> _} ->
        Tesla.Mock.json(%{"errcode" => 43101, "errmsg" => "user refuse"})
    end)

    user = Fixtures.register_user("notification-43101")
    insert_identity(user.id, :wechat, "wx-refuse-openid")
    assert {:ok, 1} = NotificationConsent.grant(user.id, :wechat, "approval_result")

    assert {:error, {:platform_rejected, 43101, "user refuse"}} =
             NotificationService.send_to_user(user.id, :wechat, "approval_result", %{
               "thing1" => %{"value" => "报名已通过"}
             })

    # 发送失败回补授权配额（沿用 refund 断言模式）
    assert {:ok, 1} = NotificationConsent.remaining(user.id, :wechat, "approval_result")
  end

  # 零外呼结构性红线（plan 008 决策回传终检用例，永久保留）：
  # adapter 注入若失效（走 Finch），此用例会真实出网而非 raise——失败即红线击穿。
  test "wechat 分支未匹配 mock 的请求直接抛错，绝不外呼" do
    Tesla.Mock.mock(fn
      %{url: "https://api.weixin.qq.com/never-mocked" <> _} ->
        Tesla.Mock.json(%{"errcode" => 0})
    end)

    assert_raise Tesla.Mock.Error, fn ->
      Client.send_notification(:wechat, "probe-openid", "probe-template", %{"k" => "v"})
    end
  end

  test "同一用户的两个不同 Enrollment 审批结果分别入队" do
    user = Fixtures.register_user("notification-signal")
    insert_identity(user.id, :wechat, "signal-openid")
    first_enrollment_id = Ecto.UUID.generate()
    second_enrollment_id = Ecto.UUID.generate()
    identities = NotificationFanout.identities(user.id)

    assert :ok =
             NotificationFanout.deliver(
               {user.id, identities},
               "approval_result",
               %{"status" => "confirmed", "enrollment_id" => first_enrollment_id},
               %{"enrollment_id" => first_enrollment_id}
             )

    assert :ok =
             NotificationFanout.deliver(
               {user.id, identities},
               "approval_result",
               %{"status" => "confirmed", "enrollment_id" => second_enrollment_id},
               %{"enrollment_id" => second_enrollment_id}
             )

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

    assert :ok =
             NotificationFanout.deliver(
               {user.id, NotificationFanout.identities(user.id)},
               "approval_reminder",
               %{
                 "enrollment_id" => enrollment_id,
                 "approval_deadline" => DateTime.to_iso8601(deadline)
               },
               %{"enrollment_id" => enrollment_id},
               :reminder_7d
             )

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
