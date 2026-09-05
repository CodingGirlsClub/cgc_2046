defmodule Cgc2046.Notifications.ServiceTest do
  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.Integrations.Wechat.Client
  alias Cgc2046.Notifications.Consent
  alias Cgc2046.Notifications.Fanout
  alias Cgc2046.Notifications.Service
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

    # wechat 分支已迁 SDK（token 由 SDK ETS 管理）——请求层走宿主 Wechat.Requester
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

    assert {:ok, 1} = Consent.grant(user.id, :wechat, "approval_result")
    assert {:ok, 2} = Consent.grant(user.id, :wechat, "approval_result")

    assert :ok =
             Service.send_to_user(user.id, :wechat, "approval_result", %{
               "status" => "approved"
             })

    assert_receive {:notification, :wechat,
                    %{"touser" => "wx-openid", "data" => %{"thing2" => %{"value" => "已通过"}}}}

    assert {:ok, 1} = Consent.remaining(user.id, :wechat, "approval_result")

    assert :ok = Service.send_to_user(user.id, :wechat, "approval_result", %{})

    assert {:error, :consent_exhausted} =
             Service.send_to_user(user.id, :wechat, "approval_result", %{})

    assert {:ok, 0} = Consent.remaining(user.id, :wechat, "approval_result")
  end

  test "三平台 adapter 使用 registry 模板并归一成功信封" do
    # 落页契约（#232）：学员类通知 → 我的报名（通知内容在那有权威展示）；
    # 管理类 → 工作台（wechat）/ 我的报名（裁剪端无 workspace tab）；
    # 未知模板兜底 profile；页面必须存在于 miniprogram/src/app.config.ts
    cases = [
      {:wechat, "approval_result", "pages/my-enrollments/index"},
      {:wechat, "payment_succeeded", "pages/my-enrollments/index"},
      {:wechat, "approval_reminder", "pages/workspace/index"},
      {:wechat, "speaker_accepted", "pages/profile/index"},
      {:tt, "approval_result", "pages/my-enrollments/index"},
      {:tt, "approval_reminder", "pages/my-enrollments/index"},
      {:xhs, "enrollment_completed", "pages/my-enrollments/index"}
    ]

    for {platform, template_key, expected_page} <- cases do
      assert :ok =
               Client.send_notification(
                 platform,
                 "openid-#{platform}",
                 "template-#{platform}",
                 %{"status" => "confirmed"},
                 template_key
               )

      assert_receive {:notification, ^platform, body}
      assert inspect(body) =~ "template-#{platform}"
      assert body["page"] == expected_page
    end
  end

  test "wechat 43101 拒收：errcode 保真出栈且 consent 原子回补" do
    Tesla.Mock.mock(fn
      %{method: :post, url: "https://api.weixin.qq.com/cgi-bin/message/subscribe/send" <> _} ->
        Tesla.Mock.json(%{"errcode" => 43101, "errmsg" => "user refuse"})
    end)

    user = Fixtures.register_user("notification-refuse")
    insert_identity(user.id, :wechat, "wx-refuse-openid")
    assert {:ok, 1} = Consent.grant(user.id, :wechat, "approval_result")

    assert {:error, {:platform_rejected, 43101, "user refuse"}} =
             Service.send_to_user(user.id, :wechat, "approval_result", %{
               "status" => "rejected"
             })

    # 发送失败回补授权配额（沿用 refund 断言模式）
    assert {:ok, 1} = Consent.remaining(user.id, :wechat, "approval_result")
  end

  # 零外呼结构性红线（plan 008 决策回传终检用例，永久保留）：
  # adapter 注入若失效（走 Finch），此用例会真实出网而非 raise——失败即红线击穿。
  test "wechat 分支未匹配 mock 的请求直接抛错，绝不外呼" do
    Tesla.Mock.mock(fn
      %{url: "https://api.weixin.qq.com/never-mocked" <> _} ->
        Tesla.Mock.json(%{"errcode" => 0})
    end)

    assert_raise Tesla.Mock.Error, fn ->
      Client.send_notification(
        :wechat,
        "probe-openid",
        "probe-template",
        %{"k" => "v"},
        "approval_result"
      )
    end
  end

  test "同一用户的两个不同 Enrollment 审批结果分别入队" do
    user = Fixtures.register_user("notification-signal")
    insert_identity(user.id, :wechat, "signal-openid")
    first_enrollment_id = Ecto.UUID.generate()
    second_enrollment_id = Ecto.UUID.generate()
    identities = Fanout.identities(user.id)

    assert :ok =
             Fanout.deliver(
               {user.id, identities},
               "approval_result",
               %{"status" => "confirmed", "enrollment_id" => first_enrollment_id},
               %{"enrollment_id" => first_enrollment_id}
             )

    assert :ok =
             Fanout.deliver(
               {user.id, identities},
               "approval_result",
               %{"status" => "confirmed", "enrollment_id" => second_enrollment_id},
               %{"enrollment_id" => second_enrollment_id}
             )

    jobs = all_enqueued(worker: Cgc2046.Notifications.NotificationWorker)
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
             Fanout.deliver(
               {user.id, Fanout.identities(user.id)},
               "approval_reminder",
               %{
                 "enrollment_id" => enrollment_id,
                 "approval_deadline" => DateTime.to_iso8601(deadline)
               },
               %{"enrollment_id" => enrollment_id},
               :reminder_7d
             )

    jobs = all_enqueued(worker: Cgc2046.Notifications.NotificationWorker)
    assert length(jobs) == 2

    assert Enum.map(jobs, & &1.args["identity_uid"]) |> Enum.sort() ==
             ["wx-openid-1", "wx-openid-2"]
  end

  test "send_to_identity 按指定身份精确投递（#3）" do
    user = Fixtures.register_user("notification-identity-target")
    insert_identity(user.id, :wechat, "wx-openid-1")
    insert_identity(user.id, :wechat, "wx-openid-2")

    {:ok, _} = Consent.grant(user.id, :wechat, "approval_result")

    assert :ok =
             Service.send_to_identity(
               user.id,
               :wechat,
               "wx-openid-2",
               "approval_result",
               %{"status" => "approved", "enrollment_id" => Ecto.UUID.generate()}
             )

    assert_receive {:notification, :wechat, %{"touser" => "wx-openid-2", "data" => data}}
    # UUID 去连字符 → character_string 兼容形状（approval_reminder 渲染同款）;
    # approval_result 此处只断 thing2 存在
    assert %{"thing2" => %{"value" => "已通过"}} = data
  end

  test "approval_reminder 渲染：UUID 单号 + ISO 截止时间 → character_string1/time11" do
    user = Fixtures.register_user("notification-reminder-render")
    insert_identity(user.id, :wechat, "wx-reminder-openid")
    {:ok, _} = Consent.grant(user.id, :wechat, "approval_reminder")

    enrollment_id = "6f0c9a1e-2b3d-4c5f-8a9b-0c1d2e3f4a5b"

    assert :ok =
             Service.send_to_user(user.id, :wechat, "approval_reminder", %{
               "enrollment_id" => enrollment_id,
               "approval_deadline" => "2026-09-02T12:00:00Z"
             })

    assert_receive {:notification, :wechat,
                    %{
                      "data" => %{
                        "character_string1" => %{"value" => "6f0c9a1e2b3d4c5f8a9b0c1d2e3f4a5b"},
                        "time11" => %{"value" => "2026-09-02 12:00"}
                      }
                    }}
  end

  test "event_reminder 渲染：thing2/time3/thing4，缺 venue 跳过" do
    user = Fixtures.register_user("notification-event-render")
    insert_identity(user.id, :wechat, "wx-event-openid")
    {:ok, _} = Consent.grant(user.id, :wechat, "event_reminder")

    assert :ok =
             Service.send_to_user(user.id, :wechat, "event_reminder", %{
               "title" => "AI 入门工作坊",
               "starts_at" => "2026-09-10T09:30:00Z",
               "venue" => nil
             })

    assert_receive {:notification, :wechat,
                    %{
                      "data" =>
                        %{
                          "thing2" => %{"value" => "AI 入门工作坊"},
                          "time3" => %{"value" => "2026-09-10 09:30"}
                        } = data
                    }}

    refute Map.has_key?(data, "thing4")
  end

  test "payment_received 渲染：thing6/thing8/amount2/character_string1，空档位跳过" do
    user = Fixtures.register_user("notification-receipt-render")
    insert_identity(user.id, :wechat, "wx-receipt-openid")
    {:ok, _} = Consent.grant(user.id, :wechat, "payment_received")

    assert :ok =
             Service.send_to_user(user.id, :wechat, "payment_received", %{
               "order_id" => "6f0c9a1e-2b3d-4c5f-8a9b-0c1d2e3f4a5b",
               "enrollment_id" => "enr-1",
               "amount" => "199.00",
               "provider" => "wechat_jsapi",
               "title" => "AI 入门工作坊",
               "tier_name" => ""
             })

    assert_receive {:notification, :wechat,
                    %{
                      "data" =>
                        %{
                          "thing6" => %{"value" => "AI 入门工作坊"},
                          "amount2" => %{"value" => "199.00"},
                          "character_string1" => %{"value" => "6f0c9a1e2b3d4c5f8a9b0c1d2e3f4a5b"}
                        } = data
                    }}

    refute Map.has_key?(data, "thing8")
  end

  test "payment_expired 渲染：character_string11/thing14/amount8/thing10（可重报文案）" do
    user = Fixtures.register_user("notification-expiry-render")
    insert_identity(user.id, :wechat, "wx-expiry-openid")
    {:ok, _} = Consent.grant(user.id, :wechat, "payment_expired")

    assert :ok =
             Service.send_to_user(user.id, :wechat, "payment_expired", %{
               "order_id" => "6f0c9a1e-2b3d-4c5f-8a9b-0c1d2e3f4a5b",
               "enrollment_id" => "enr-1",
               "amount" => "199.00",
               "provider" => "wechat_jsapi",
               "title" => "AI 入门工作坊",
               "re_enrollable" => "true"
             })

    assert_receive {:notification, :wechat,
                    %{
                      "data" => %{
                        "character_string11" => %{"value" => "6f0c9a1e2b3d4c5f8a9b0c1d2e3f4a5b"},
                        "thing14" => %{"value" => "AI 入门工作坊"},
                        "amount8" => %{"value" => "199.00"},
                        "thing10" => %{"value" => "订单超时作废，报名截止前可重新报名"}
                      }
                    }}
  end

  # ── #406 五模板渲染映射（模板 ID 与字段编号以公众平台「我的模板 → 详情」为准）──

  test "enrollment_submitted 渲染：thing1 活动名 + thing5 固定提示" do
    user = Fixtures.register_user("notification-submitted-render")
    insert_identity(user.id, :wechat, "wx-submitted-openid")
    {:ok, _} = Consent.grant(user.id, :wechat, "enrollment_submitted")

    assert :ok =
             Service.send_to_user(user.id, :wechat, "enrollment_submitted", %{
               "enrollment_id" => "enr-1",
               "title" => "AI 入门工作坊"
             })

    assert_receive {:notification, :wechat,
                    %{
                      "data" => %{
                        "thing1" => %{"value" => "AI 入门工作坊"},
                        "thing5" => %{"value" => "有新的待审批报名，请前往工作台处理"}
                      }
                    }}
  end

  test "enrollment_completed 渲染：thing1 活动名 + character_string10 报名号" do
    user = Fixtures.register_user("notification-completed-render")
    insert_identity(user.id, :wechat, "wx-completed-openid")
    {:ok, _} = Consent.grant(user.id, :wechat, "enrollment_completed")

    assert :ok =
             Service.send_to_user(user.id, :wechat, "enrollment_completed", %{
               "enrollment_id" => "6f0c9a1e-2b3d-4c5f-8a9b-0c1d2e3f4a5b",
               "title" => "AI 入门工作坊"
             })

    assert_receive {:notification, :wechat,
                    %{
                      "data" => %{
                        "thing1" => %{"value" => "AI 入门工作坊"},
                        "character_string10" => %{"value" => "6f0c9a1e2b3d4c5f8a9b0c1d2e3f4a5b"}
                      }
                    }}
  end

  test "payment_succeeded 渲染：character_string2 订单号 + amount3 金额" do
    user = Fixtures.register_user("notification-paid-render")
    insert_identity(user.id, :wechat, "wx-paid-openid")
    {:ok, _} = Consent.grant(user.id, :wechat, "payment_succeeded")

    assert :ok =
             Service.send_to_user(user.id, :wechat, "payment_succeeded", %{
               "order_id" => "6f0c9a1e-2b3d-4c5f-8a9b-0c1d2e3f4a5b",
               "enrollment_id" => "enr-1",
               "amount" => "199.00",
               "provider" => "wechat_jsapi"
             })

    assert_receive {:notification, :wechat,
                    %{
                      "data" => %{
                        "character_string2" => %{"value" => "6f0c9a1e2b3d4c5f8a9b0c1d2e3f4a5b"},
                        "amount3" => %{"value" => "199.00"}
                      }
                    }}
  end

  test "refund_succeeded 渲染：订单号/金额/状态，退款时间无数据源缺省跳过" do
    user = Fixtures.register_user("notification-refunded-render")
    insert_identity(user.id, :wechat, "wx-refunded-openid")
    {:ok, _} = Consent.grant(user.id, :wechat, "refund_succeeded")

    assert :ok =
             Service.send_to_user(user.id, :wechat, "refund_succeeded", %{
               "order_id" => "6f0c9a1e-2b3d-4c5f-8a9b-0c1d2e3f4a5b",
               "enrollment_id" => "enr-1",
               "amount" => "199.00",
               "provider" => "wechat_jsapi"
             })

    assert_receive {:notification, :wechat,
                    %{
                      "data" =>
                        %{
                          "character_string2" => %{"value" => "6f0c9a1e2b3d4c5f8a9b0c1d2e3f4a5b"},
                          "amount3" => %{"value" => "199.00"},
                          "phrase8" => %{"value" => "退款成功"}
                        } = data
                    }}

    refute Map.has_key?(data, "time5")
  end

  test "refund_failed 渲染：订单编号/金额/固定原因与状态" do
    user = Fixtures.register_user("notification-refundfail-render")
    insert_identity(user.id, :wechat, "wx-refundfail-openid")
    {:ok, _} = Consent.grant(user.id, :wechat, "refund_failed")

    assert :ok =
             Service.send_to_user(user.id, :wechat, "refund_failed", %{
               "order_id" => "6f0c9a1e-2b3d-4c5f-8a9b-0c1d2e3f4a5b",
               "enrollment_id" => "enr-1",
               "amount" => "199.00",
               "provider" => "wechat_jsapi"
             })

    assert_receive {:notification, :wechat,
                    %{
                      "data" => %{
                        "character_string2" => %{"value" => "6f0c9a1e2b3d4c5f8a9b0c1d2e3f4a5b"},
                        "amount1" => %{"value" => "199.00"},
                        "thing3" => %{"value" => "退款未到账，平台将重试或与你联系"},
                        "phrase5" => %{"value" => "退款失败"}
                      }
                    }}
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
