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
      {:wechat, "speaker_accepted", "pages/workspace/index"},
      {:tt, "approval_result", "pages/my-enrollments/index"},
      {:tt, "approval_reminder", "pages/my-enrollments/index"},
      {:xhs, "enrollment_completed", "pages/my-enrollments/index"},
      # #594 开班/未达阈值/改期 → 我的报名（学员类；不深链 event-detail 的理由
      # 见 client.ex 落页契约注释）
      {:wechat, "event_qualification_confirmed", "pages/my-enrollments/index"},
      {:wechat, "event_qualification_underfilled", "pages/my-enrollments/index"},
      {:wechat, "event_schedule_changed", "pages/my-enrollments/index"},
      # #585 管理侧开班结果 → 工作台（管理类；后续处理面在那）
      {:wechat, "event_qualification_manager", "pages/workspace/index"},
      # 裁剪端分支（tt/xhs）对四模板同款不变（无 workspace tab，一律我的报名）
      {:tt, "event_qualification_underfilled", "pages/my-enrollments/index"},
      {:tt, "event_qualification_manager", "pages/my-enrollments/index"},
      {:xhs, "event_schedule_changed", "pages/my-enrollments/index"},
      {:xhs, "event_qualification_manager", "pages/my-enrollments/index"},
      # 未知模板兜底不变
      {:wechat, "unknown_template_key", "pages/profile/index"}
    ]

    # 主理人指派深链（#558 后续）：wechat 全量端落活动详情页（带 event_id，
    # 被指派者点开即见「扫码核销」入口）；tt/xhs 裁剪端维持我的报名；
    # data 缺 event_id 时回落通用路由（未知模板兜底 profile），不拼坏 URL
    event_id = "0dcb3ad6-c4c2-4baf-84b5-6792e4234453"

    assert :ok =
             Client.send_notification(
               :wechat,
               "openid-wechat",
               "template-wechat",
               %{"event_id" => event_id, "title" => "押金制黑客松"},
               "event_moderator_assigned"
             )

    assert_receive {:notification, :wechat, body}
    assert body["page"] == "pages/event-detail/index?id=#{event_id}&kind=event"

    assert :ok =
             Client.send_notification(
               :tt,
               "openid-tt",
               "template-tt",
               %{"event_id" => event_id},
               "event_moderator_assigned"
             )

    assert_receive {:notification, :tt, body_tt}
    assert body_tt["page"] == "pages/my-enrollments/index"

    assert :ok =
             Client.send_notification(
               :wechat,
               "openid-wechat",
               "template-wechat",
               %{"title" => "无 id 的脏数据"},
               "event_moderator_assigned"
             )

    assert_receive {:notification, :wechat, body_fallback}
    assert body_fallback["page"] == "pages/profile/index"

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

  # #594 复发守卫：registry 是全量模板真源，落页靠 client.ex 的两张名单 + 一条
  # 深链分支。名单漏登记不报错——静默兜底 profile（本机通知记录，服务端下发的
  # 通知不在其中，点开是空页；#594 的失败形态）。故 registry 每个 template_key
  # 都必须有非 profile 落页；profile 只留给显式记录的取舍。
  test "registry 全量模板都有非 profile 落页（名单漂移即红）" do
    # speaker_completed 双受众（管理者 + speaker 本人）维持兜底 profile——已知
    # 取舍：speaker 侧点开无权威页，多数方（管理者）可从 workspace speakers
    # 面板查看（client.ex 落页契约注释）。白名单 = 「有意兜底」的唯一出口。
    deliberate_profile_fallback = ~w(speaker_completed)

    registry_keys =
      Cgc2046.Notifications.NotificationWorker.types()
      |> Enum.map(& &1.template_key)
      |> Enum.uniq()

    # 守卫自身有效：registry 非空且含已知 key（防 types/0 被改空后守卫空转通过）
    assert "event_qualification_underfilled" in registry_keys

    for template_key <- registry_keys, template_key not in deliberate_profile_fallback do
      # 深链模板（event_moderator_assigned）需 event_id 才走深链分支——带 id
      # 发送即覆盖「data 完整」的真实态；其余模板 data 不影响落页。
      assert :ok =
               Client.send_notification(
                 :wechat,
                 "openid-drift",
                 "template-drift",
                 %{"event_id" => "0dcb3ad6-c4c2-4baf-84b5-6792e4234453"},
                 template_key
               )

      assert_receive {:notification, :wechat, body}

      assert body["page"] != "pages/profile/index",
             "template_key #{inspect(template_key)} 落 profile——补进 client.ex 的 " <>
               "@learner_templates/@manager_templates 或深链分支，否则通知点开是" <>
               "本机通知记录空页（#594）"
    end

    # 白名单反向锁定：speaker_completed 落页若变更，此处逼出白名单同步（防
    # 白名单变成「永久豁免」而无人再审视）
    assert :ok =
             Client.send_notification(
               :wechat,
               "openid-drift",
               "template-drift",
               %{"event_id" => "0dcb3ad6-c4c2-4baf-84b5-6792e4234453"},
               "speaker_completed"
             )

    assert_receive {:notification, :wechat, body}
    assert body["page"] == "pages/profile/index"
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

  # #606 Stage③：time/1 修 +8 时区折算（starts_at / approval_deadline 是 UTC 瞬时，
  # 前端按设备本地时区显示；修复前通知比用户面早 8 小时）
  test "approval_reminder 渲染：UUID 单号 + ISO 截止时间 → character_string1/time11（北京时间，含跨日）" do
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
                        "time11" => %{"value" => "2026-09-02 20:00"}
                      }
                    }}

    # 跨日边界：UTC 17:30 → 北京时间次日 01:30
    {:ok, _} = Consent.grant(user.id, :wechat, "approval_reminder")

    assert :ok =
             Service.send_to_user(user.id, :wechat, "approval_reminder", %{
               "enrollment_id" => enrollment_id,
               "approval_deadline" => "2026-09-20T17:30:00Z"
             })

    assert_receive {:notification, :wechat,
                    %{"data" => %{"time11" => %{"value" => "2026-09-21 01:30"}}}}
  end

  test "event_reminder 渲染：thing2/time3（北京时间）/thing4，缺 venue 跳过" do
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
                          "time3" => %{"value" => "2026-09-10 17:30"}
                        } = data
                    }}

    refute Map.has_key?(data, "thing4")

    # 跨日边界：UTC 17:30 → 北京时间次日 01:30
    {:ok, _} = Consent.grant(user.id, :wechat, "event_reminder")

    assert :ok =
             Service.send_to_user(user.id, :wechat, "event_reminder", %{
               "title" => "跨日活动",
               "starts_at" => "2026-09-20T17:30:00Z",
               "venue" => "上海 徐汇"
             })

    assert_receive {:notification, :wechat,
                    %{
                      "data" => %{
                        "time3" => %{"value" => "2026-09-21 01:30"},
                        "thing4" => %{"value" => "上海 徐汇"}
                      }
                    }}
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

  test "enrollment_completed 渲染：thing1 活动名 + character_string10 报名号（#664 落页=我的报名）" do
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
                      },
                      "page" => page
                    }}

    # #664：授权入口补齐后这条通知才第一次真正可达——落页必须是报名结果权威面
    assert page == "pages/my-enrollments/index"
  end

  # #546：三字段逐字锁死（相等断言同时锁死键集——多写一个字段即红）+ 显式断言
  # 无 date5（核销时间本批有意跳过，理由见 service.ex 模块注释），落页断言到
  # my-enrollments（码与二维码在该页报名卡渲染，profile 是空页）。
  test "enrollment_check_in_code 渲染：thing8 活动名 + character_string15 核销码 + thing9 提示（无 date5）" do
    user = Fixtures.register_user("notification-check-in-code-render")
    insert_identity(user.id, :wechat, "wx-check-in-code-openid")
    {:ok, _} = Consent.grant(user.id, :wechat, "enrollment_check_in_code")

    assert :ok =
             Service.send_to_user(user.id, :wechat, "enrollment_check_in_code", %{
               "enrollment_id" => "6f0c9a1e-2b3d-4c5f-8a9b-0c1d2e3f4a5b",
               "title" => "AI 入门工作坊",
               "check_in_code" => "042317",
               # 防「以后有人把 date5 接到 starts_at」：即使 data 携带时间键也不得渲染 date5
               "starts_at" => "2026-09-20T07:00:00Z"
             })

    assert_receive {:notification, :wechat, %{"data" => data, "page" => page}}

    assert data == %{
             "thing8" => %{"value" => "AI 入门工作坊"},
             "character_string15" => %{"value" => "042317"},
             "thing9" => %{"value" => "到店出示此码核销"}
           }

    refute Map.has_key?(data, "date5"), "date5（核销时间）本批有意跳过——触发时尚未核销"

    assert page == "pages/my-enrollments/index",
           "核销码通知必须落能看到码的页（我的报名）"
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

  # ── #606 七模板渲染映射（2026-09-16 平台选用即时生效；字段编号以回报的
  #    「我的模板 → 详情」为准：thing4/number16/thing7/thing14/thing6/date2…）──

  test "event_qualification_confirmed 渲染：thing4 活动名 + number16 已确认人数 + thing7 开班提示" do
    data =
      send_and_capture("event_qualification_confirmed", %{
        "event_id" => Ecto.UUID.generate(),
        "title" => "AI 入门工作坊",
        "min_participants" => 3,
        "confirmed_count" => 4
      })

    assert data == %{
             "thing4" => %{"value" => "AI 入门工作坊"},
             "number16" => %{"value" => "4"},
             "thing7" => %{"value" => "已达最低成班人数3人"}
           }

    # 防御分支：min 缺失时 thing7 整键跳过（不留「已达最低成班人数人」半句）
    no_min =
      send_and_capture("event_qualification_confirmed", %{"title" => "活动", "confirmed_count" => 2})

    assert no_min == %{"thing4" => %{"value" => "活动"}, "number16" => %{"value" => "2"}}
  end

  test "event_qualification_manager 渲染：thing2 活动名 + thing5 outcome 驱动双文案（#585/#720）" do
    confirmed =
      send_and_capture("event_qualification_manager", %{
        "title" => "AI 入门工作坊",
        "min_participants" => 3,
        "outcome" => "confirmed"
      })

    assert confirmed == %{
             "thing2" => %{"value" => "AI 入门工作坊"},
             "thing5" => %{"value" => "已达最低人数3人，活动成班"}
           }

    underfilled =
      send_and_capture("event_qualification_manager", %{
        "title" => "AI 入门工作坊",
        "min_participants" => 3,
        "outcome" => "underfilled"
      })

    assert underfilled == %{
             "thing2" => %{"value" => "AI 入门工作坊"},
             "thing5" => %{"value" => "未达最低人数3人，已取消并发起退款"}
           }
  end

  test "event_qualification_underfilled 渲染：thing1 活动名 + thing5 未达阈值文案" do
    data =
      send_and_capture("event_qualification_underfilled", %{
        "event_id" => Ecto.UUID.generate(),
        "title" => "AI 入门工作坊",
        "min_participants" => 3,
        "confirmed_count" => 1
      })

    # confirmed_count 平台无 number 槽位 → 不下发（精确等值即断言无多余键）
    assert data == %{
             "thing1" => %{"value" => "AI 入门工作坊"},
             "thing5" => %{"value" => "未达最低成班人数3人，活动未成行"}
           }
  end

  test "event_schedule_changed 渲染：date2 北京时间年月日+时刻 / thing5 地点 / 缺值跳过" do
    data =
      send_and_capture("event_schedule_changed", %{
        "event_id" => Ecto.UUID.generate(),
        "title" => "AI 入门工作坊",
        "starts_at" => "2026-09-20T07:00:00Z",
        "venue" => "上海 徐汇"
      })

    assert data == %{
             "thing1" => %{"value" => "AI 入门工作坊"},
             "date2" => %{"value" => "2026年9月20日 15:00"},
             "thing5" => %{"value" => "上海 徐汇"}
           }

    # 跨日边界：UTC 17:30 → 北京时间次日 01:30（+8 折算与日期进位同时钉住）
    crossing =
      send_and_capture("event_schedule_changed", %{
        "title" => "跨日活动",
        "starts_at" => "2026-09-20T17:30:00Z",
        "venue" => nil
      })

    assert crossing == %{
             "thing1" => %{"value" => "跨日活动"},
             "date2" => %{"value" => "2026年9月21日 01:30"}
           }

    # 非法 starts_at → date2 跳过而非发垃圾串（date 槽位格式非法会整条 47003）
    bad =
      send_and_capture("event_schedule_changed", %{"title" => "坏数据", "starts_at" => "not-a-date"})

    assert bad == %{"thing1" => %{"value" => "坏数据"}}
  end

  test "event_moderator_assigned 渲染：thing1 活动名 + thing5 固定指派文案" do
    data =
      send_and_capture("event_moderator_assigned", %{
        "event_id" => Ecto.UUID.generate(),
        "title" => "押金制黑客松"
      })

    assert data == %{
             "thing1" => %{"value" => "押金制黑客松"},
             "thing5" => %{"value" => "你已被指派为该活动主理人"}
           }
  end

  test "speaker_accepted 渲染：thing14 活动名 + thing6 已接受（invitation_id 不下发）" do
    data =
      send_and_capture("speaker_accepted", %{
        "speaker_invitation_id" => Ecto.UUID.generate(),
        "title" => "AI 分享"
      })

    assert data == %{
             "thing14" => %{"value" => "AI 分享"},
             "thing6" => %{"value" => "已接受"}
           }
  end

  test "speaker_completed 渲染：thing1 活动名 + thing4 固定归档文案；speaker 面无 title 仍有 thing4" do
    manager =
      send_and_capture("speaker_completed", %{
        "speaker_invitation_id" => Ecto.UUID.generate(),
        "title" => "AI 分享"
      })

    assert manager == %{
             "thing1" => %{"value" => "AI 分享"},
             "thing4" => %{"value" => "分享已完成，材料已归档"}
           }

    # speaker 本人面 data 只有 speaker_invitation_id（speaker_subscriber.ex:92-96）：
    # 固定 thing4 保底 ⇒ 不会给微信发空 data
    speaker =
      send_and_capture("speaker_completed", %{"speaker_invitation_id" => Ecto.UUID.generate()})

    assert speaker == %{"thing4" => %{"value" => "分享已完成，材料已归档"}}
  end

  test "learning_stagnation 渲染：thing1 课程名 + thing4 固定停滞提醒（run_id/enrollment_id 不下发）" do
    data =
      send_and_capture("learning_stagnation", %{
        "enrollment_id" => Ecto.UUID.generate(),
        "run_id" => Ecto.UUID.generate(),
        "title" => "AI 入门"
      })

    assert data == %{
             "thing1" => %{"value" => "AI 入门"},
             "thing4" => %{"value" => "长时间未继续学习，记得回来完成学习"}
           }
  end

  # #606 边界算术：thing ≤20 字。{min} 位数 1/2/3 → underfilled 16/17/18 字、
  # confirmed 10/11/12 字；title（thing/1 顶 20）与动态串是**两个独立字段**，
  # 不存在 title 截断挤占动态串预算的问题。
  test "成班动态文案字符预算：min 1/2/3 位均 ≤20 字，title 顶格 20 字不影响动态串" do
    cases = [
      {1, "未达最低成班人数1人，活动未成行", "已达最低成班人数1人"},
      {99, "未达最低成班人数99人，活动未成行", "已达最低成班人数99人"},
      {999, "未达最低成班人数999人，活动未成行", "已达最低成班人数999人"}
    ]

    long_title = String.duplicate("活", 25)

    for {min, underfilled_copy, confirmed_copy} <- cases do
      assert String.length(underfilled_copy) <= 20
      assert String.length(confirmed_copy) <= 20

      underfilled =
        send_and_capture("event_qualification_underfilled", %{
          "title" => long_title,
          "min_participants" => min,
          "confirmed_count" => min
        })

      confirmed =
        send_and_capture("event_qualification_confirmed", %{
          "title" => long_title,
          "min_participants" => min,
          "confirmed_count" => min
        })

      assert underfilled["thing5"] == %{"value" => underfilled_copy}
      assert confirmed["thing7"] == %{"value" => confirmed_copy}
      # title 被 thing/1 截到 20 字；动态串各自独立，值不受影响
      assert String.length(underfilled["thing1"]["value"]) == 20
      assert String.length(confirmed["thing4"]["value"]) == 20
    end
  end

  test "min 6 位时动态串被 thing/1 顶到 20 字（保 API 不 47003）" do
    data =
      send_and_capture("event_qualification_underfilled", %{
        "title" => "活动",
        "min_participants" => 1_000_000,
        "confirmed_count" => 0
      })

    assert String.length(data["thing5"]["value"]) == 20
    assert String.starts_with?(data["thing5"]["value"], "未达最低成班人数")
  end

  # #606 复发守卫：render/3 缺子句的 key 会落 :162 的兜底 passthrough——把逻辑键
  # （title/event_id/starts_at…）原样当微信字段名发出（微信 47003 拒收）。本测试
  # 按 registry 全量 key 用样例 data 实发，断言送出的字段名**全部**是微信合法
  # 关键词编号且值非空字符串；新增模板忘写子句即红。
  @wechat_field ~r/^(thing|number|letter|symbol|character_string|time|date|amount|phone_number|car_number|name|phrase)\d+$/

  test "registry 全量模板都有 wechat 字段渲染子句（passthrough 即红）" do
    registry_keys =
      Cgc2046.Notifications.NotificationWorker.types()
      |> Enum.map(& &1.template_key)
      |> Enum.uniq()

    # 守卫自身有效：key 数须等于 config/runtime.exs 的 19 键集合（防表被改空）
    assert length(registry_keys) == 19

    for template_key <- registry_keys do
      data = send_and_capture(template_key, sample_data(template_key))

      assert map_size(data) > 0, "#{template_key} 渲染出空 data（微信 47003 拒收）"

      for {field, value} <- data do
        assert field =~ @wechat_field,
               "#{template_key} 送出非微信字段名 #{inspect(field)}——render/3 缺子句走了 " <>
                 "passthrough（#606）"

        assert %{"value" => text} = value
        assert is_binary(text) and text != ""
      end
    end
  end

  defp send_and_capture(template_key, data) do
    user = Fixtures.register_user("render-#{template_key}")
    insert_identity(user.id, :wechat, "wx-render-#{Ecto.UUID.generate()}")
    {:ok, _} = Consent.grant(user.id, :wechat, template_key)

    assert :ok = Service.send_to_user(user.id, :wechat, template_key, data)

    assert_receive {:notification, :wechat, %{"data" => rendered}}
    rendered
  end

  # 样例值按 registry data_keys 的键名给类型正确的值（整数键给整数、时间键给 ISO），
  # 保证「渲染出的空 data / 非字段名」只可能来自缺子句，而不是样例值类型错。
  defp sample_data(template_key) do
    entry = Cgc2046.Notifications.NotificationWorker.type(template_key)

    Map.new(entry.data_keys, fn
      "starts_at" -> {"starts_at", "2026-09-20T07:00:00Z"}
      "approval_deadline" -> {"approval_deadline", "2026-09-20T07:00:00Z"}
      "min_participants" -> {"min_participants", 3}
      "outcome" -> {"outcome", "confirmed"}
      "confirmed_count" -> {"confirmed_count", 2}
      "capacity_seq" -> {"capacity_seq", 7}
      "re_enrollable" -> {"re_enrollable", "true"}
      key -> {key, "样例"}
    end)
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
