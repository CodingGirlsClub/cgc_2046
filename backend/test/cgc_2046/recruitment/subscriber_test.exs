defmodule Cgc2046.Recruitment.SubscriberTest do
  @moduledoc """
  U4 段位通知验收（R14/R21；Covers AE10）。

  R14 阶段通知表逐行断言（六行 = 六订阅场景）：

  | 流转 | template_key | 内容要点 |
  |---|---|---|
  | 网申提交 | volunteer_application_submitted | 提交确认 |
  | 初审通过 | volunteer_application_interview | 面试安排（群面时间 + 入群方式）|
  | 群面通过 | volunteer_application_training | 训练营预约（排期 + 课程入口）|
  | 训练营完成·分配 | volunteer_application_assigned | 分配结果（场次 + 课程任务）|
  | 任一拒绝 | volunteer_application_rejected | 拒绝通知（含原因）|
  | 取消 | volunteer_application_canceled | 取消通知 |

  双通道语义（KTD6）：小程序订阅消息走既有全链（Fanout → NotificationWorker →
  Service.render(:wechat, …)），**邮件是唯一保底通道**（发往 R9 档案联系邮箱，
  Swoosh 内联 HTML + 尽力而为——失败只记日志/遥测，不阻塞段位流转）。
  未授权订阅消息（Consent 配额 0）不报错、不产生小程序投递、邮件照发（AE10）。

  async: false —— 邮件适配器与 web_base_url 走应用环境改写（同
  speaker_invitation_email_test）；真实信号链用例终止应用级订阅方（同
  async_signal_test），避免两个消费者对同一 claim 竞争。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  require Ash.Query

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Notifications.{Consent, NotificationWorker}

  alias Cgc2046.Recruitment.{
    NotificationEmail,
    RecruitmentCohort,
    ResumeProfile,
    Subscriber,
    VolunteerApplication
  }

  alias Cgc2046.Workflows.{JidoAdapter, SignalIdempotency, SignalPublishWorker, SignalSubscriber}

  @submitted_signal "volunteer_application.submitted"
  @interview_signal "volunteer_application.interview"
  @training_signal "volunteer_application.training"
  @assigned_signal "volunteer_application.assigned"
  @rejected_signal "volunteer_application.rejected"
  @canceled_signal "volunteer_application.canceled"

  @telemetry_event [:cgc2046, :recruitment, :notification_email]

  # 联系邮箱与账号邮箱刻意不同：R9 的收件地址是档案联系邮箱，不是账号 email
  @contact_email "volunteer-contact@example.com"

  defmodule FailingAdapter do
    use Swoosh.Adapter

    @impl true
    def deliver(_email, _config), do: {:error, :send_cloud_timeout}
  end

  setup do
    test_pid = self()

    Tesla.Mock.mock(fn
      %{method: :post, url: "https://api.weixin.qq.com/cgi-bin/message/subscribe/send" <> _} = env ->
        send(test_pid, {:notification, :wechat, Jason.decode!(env.body)})
        Tesla.Mock.json(%{"errcode" => 0})
    end)

    on_exit(fn ->
      Application.put_env(:cgc_2046, Cgc2046.Mailer, adapter: Swoosh.Adapters.Test)
    end)

    :ok
  end

  setup do
    creator = Fixtures.platform_admin("recruit-sub")
    workspace = Fixtures.create_workspace(creator)

    owner = Fixtures.register_user("recruit-sub-owner")
    Fixtures.add_member(workspace, owner, [:owner])

    # 申请人不是台成员（R15：项目分配时才邀请入台）
    applicant = Fixtures.register_user("recruit-sub-applicant")

    cohort =
      open_cohort(workspace, owner, "第 1 批", %{
        starts_at: DateTime.add(DateTime.utc_now(), 7, :day) |> DateTime.truncate(:second),
        ends_at: DateTime.add(DateTime.utc_now(), 21, :day) |> DateTime.truncate(:second)
      })

    insert_identity(applicant.id, "recruit-sub-openid")
    upsert_profile(workspace, applicant, %{full_name: "申请人甲", contact_email: @contact_email})

    %{workspace: workspace, owner: owner, applicant: applicant, cohort: cohort}
  end

  describe "R14 阶段通知表逐行（六订阅场景）" do
    test "网申提交 → 提交确认邮件 + 小程序通知入队（第 1 行）", ctx do
      %{workspace: ws, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, application} = apply_for(ws, applicant, cohort, :tutor)

      assert :ok = deliver(@submitted_signal, application)

      email = assert_email()
      assert {_, @contact_email} = List.first(email.to)
      assert email.subject =~ "已提交"
      assert email.html_body =~ "申请人甲"
      assert email.html_body =~ "第 1 批"
      assert email.html_body =~ "教程研究员"

      assert_enqueued(
        worker: NotificationWorker,
        args: %{"template_key" => "volunteer_application_submitted", "user_id" => applicant.id}
      )

      assert [%{"data" => data}] = enqueued_data("volunteer_application_submitted")
      assert data["cohort_name"] == "第 1 批"
      assert data["position_label"] == "教程研究员"
    end

    test "初审通过 → 面试安排（含群面时间与入群方式）（第 2 行）", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, application} = apply_for(ws, applicant, cohort, :event_moderator)
      assert {:ok, application} = advance(ws, owner, application, :advance_to_interview)

      assert :ok = deliver(@interview_signal, application)

      email = assert_email()
      assert email.subject =~ "面试"
      assert email.html_body =~ "群面时间"
      assert email.html_body =~ beijing(cohort.starts_at)
      assert email.html_body =~ "入群"

      assert [%{"data" => data}] = enqueued_data("volunteer_application_interview")
      assert data["cohort_name"] == "第 1 批"
      assert data["group_time"] == DateTime.to_iso8601(cohort.starts_at)
    end

    test "群面通过 → 训练营预约（含排期与课程入口）（第 3 行）", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, application} = apply_for(ws, applicant, cohort, :coach)
      assert {:ok, application} = advance(ws, owner, application, :advance_to_interview)
      assert {:ok, application} = advance(ws, owner, application, :advance_to_training)

      assert :ok = deliver(@training_signal, application)

      email = assert_email()
      assert email.subject =~ "训练营"
      assert email.html_body =~ "排期"
      assert email.html_body =~ beijing(cohort.starts_at)
      assert email.html_body =~ "邀请码"

      assert [%{"data" => data}] = enqueued_data("volunteer_application_training")
      assert data["cohort_name"] == "第 1 批"
      assert data["training_starts_at"] == DateTime.to_iso8601(cohort.starts_at)
    end

    test "训练营完成·分配 → 分配结果（含分配到的场次与课程任务）（第 4 行）", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort} = ctx

      event = EventFixtures.create_event(ws, owner, %{title: "上海主理人场次"})

      assert {:ok, application} = apply_for(ws, applicant, cohort, :event_moderator)
      assert {:ok, application} = advance(ws, owner, application, :advance_to_interview)
      assert {:ok, application} = advance(ws, owner, application, :advance_to_training)

      assert {:ok, application} =
               advance(ws, owner, application, :assign, %{
                 assigned_event_id: event.id,
                 assignment_note: "负责开场与签到"
               })

      assert :ok = deliver(@assigned_signal, application)

      email = assert_email()
      assert email.subject =~ "分配"
      assert email.html_body =~ "上海主理人场次"
      assert email.html_body =~ "负责开场与签到"

      assert [%{"data" => data}] = enqueued_data("volunteer_application_assigned")
      assert data["event_title"] == "上海主理人场次"
      assert data["assignment_note"] == "负责开场与签到"
    end

    test "任一拒绝 → 拒绝通知（含原因）（第 5 行）", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, application} = apply_for(ws, applicant, cohort, :tutor)
      assert {:ok, application} = advance(ws, owner, application, :advance_to_interview)

      assert {:ok, rejected} =
               advance(ws, owner, application, :reject, %{reason: "本轮名额已满，欢迎下一批再申"})

      assert :ok = deliver(@rejected_signal, rejected)

      email = assert_email()
      assert email.subject =~ "结果"
      assert email.html_body =~ "本轮名额已满，欢迎下一批再申"

      assert [%{"data" => data}] = enqueued_data("volunteer_application_rejected")
      assert data["rejection_reason"] == "本轮名额已满，欢迎下一批再申"
    end

    test "取消 → 取消通知（备注选填）（第 6 行）", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, application} = apply_for(ws, applicant, cohort, :coach)

      assert {:ok, canceled} =
               advance(ws, owner, application, :cancel, %{reason: "申请人主动放弃"})

      assert :ok = deliver(@canceled_signal, canceled)

      email = assert_email()
      assert email.subject =~ "取消"
      assert email.html_body =~ "申请人主动放弃"

      assert [%{"data" => data}] = enqueued_data("volunteer_application_canceled")
      assert data["cancel_note"] == "申请人主动放弃"
    end
  end

  describe "收件地址与降级（R9/AE10）" do
    test "手机号建号账号（账号无邮箱）→ 邮件仍达档案联系邮箱", ctx do
      %{workspace: ws, cohort: cohort} = ctx

      phone_user = register_phone_user("+8613800001024")
      assert phone_user.email == nil

      upsert_profile(ws, phone_user, %{
        full_name: "申请人乙",
        contact_email: "phone-only@example.com"
      })

      assert {:ok, application} = apply_for(ws, phone_user, cohort, :tutor)

      assert :ok = deliver(@submitted_signal, application)

      email = assert_email()
      assert {_, "phone-only@example.com"} = List.first(email.to)
      assert email.html_body =~ "申请人乙"
    end

    test "无简历档案 → 不发邮件但小程序通知照常入队（邮件不可达只记日志）", ctx do
      %{workspace: ws, applicant: applicant, cohort: cohort} = ctx

      # 未建档案的申请人（R9 档案是邮件唯一地址来源；防御分支不发邮件）
      profileless = Fixtures.register_user("recruit-sub-no-profile")
      insert_identity(profileless.id, "recruit-sub-no-profile-openid")

      assert {:ok, application} = apply_for(ws, profileless, cohort, :tutor)

      assert :ok = deliver(@submitted_signal, application)

      refute_receive {:email, _email}, 200

      assert [%{"user_id" => user_id, "identity_uid" => uid}] =
               enqueued_data("volunteer_application_submitted")

      assert user_id == profileless.id
      assert uid == "recruit-sub-no-profile-openid"

      # 已有档案的申请人（setup 内 applicant）走同一路径仍可达邮件
      assert {:ok, with_profile} = apply_for(ws, applicant, cohort, :tutor)
      assert :ok = deliver(@submitted_signal, with_profile)
      assert_email()
    end

    test "同一信号重复投递 → 幂等：只发一次邮件、一条通知、一次 claim", ctx do
      %{workspace: ws, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, application} = apply_for(ws, applicant, cohort, :tutor)

      assert :ok = deliver(@submitted_signal, application)
      assert_email()

      assert :duplicate = deliver(@submitted_signal, application)
      refute_receive {:email, _email}, 200

      assert claim_rows(@submitted_signal) == 1
      assert length(enqueued_data("volunteer_application_submitted")) == 1
    end
  end

  describe "小程序通道：授权两态（R21/AE10）" do
    test "已授权 → NotificationWorker 投递订阅消息（渲染字段 + 配额消费）", ctx do
      %{workspace: ws, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, application} = apply_for(ws, applicant, cohort, :tutor)
      assert {:ok, _} = Consent.grant(applicant.id, :wechat, "volunteer_application_submitted")

      assert :ok = deliver(@submitted_signal, application)

      assert [job] = enqueued_data("volunteer_application_submitted")

      assert :ok = perform_job(NotificationWorker, job)

      assert_receive {:notification, :wechat, %{"data" => data}}
      # 槽位对齐实际模板（2026-09-18 申请）：thing7=批次名 / thing5=申请职位
      assert data["thing7"] == %{"value" => "第 1 批"}
      assert data["thing5"] == %{"value" => "教程研究员"}

      assert {:ok, 0} =
               Consent.remaining(applicant.id, :wechat, "volunteer_application_submitted")
    end

    test "未授权（AE10）→ 邮件送达、无异常、不产生小程序投递", ctx do
      %{workspace: ws, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, application} = apply_for(ws, applicant, cohort, :tutor)

      # 不 grant ⇒ 发送侧 Consent.take 命中零行（一次性授权未获得）
      assert :ok = deliver(@submitted_signal, application)

      email = assert_email()
      assert {_, @contact_email} = List.first(email.to)

      assert [job] = enqueued_data("volunteer_application_submitted")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:discard, "consent_exhausted"} = perform_job(NotificationWorker, job)
        end)

      assert log =~ "consent exhausted"
      refute_received {:notification, :wechat, _}
    end
  end

  describe "best-effort：邮件失败不阻塞段位流转" do
    test "适配器故障 → deliver/2 内化失败并落遥测（不抛出）" do
      test_pid = self()

      :telemetry.attach(
        "recruitment-email-failure",
        @telemetry_event,
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach("recruitment-email-failure") end)

      Application.put_env(:cgc_2046, Cgc2046.Mailer, adapter: FailingAdapter)

      assert :ok =
               NotificationEmail.deliver(:submitted, %{
                 to: "failing@example.com",
                 applicant_name: "申请人丙",
                 position_label: "教程研究员",
                 cohort_name: "第 1 批"
               })

      assert_receive {:telemetry, @telemetry_event, %{count: 1},
                      %{stage: :submitted, reason: category}}

      assert category == :send_cloud_timeout
    end

    test "邮件通道故障时段位流转照常完成，订阅方仍返回 :ok", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, application} = apply_for(ws, applicant, cohort, :tutor)
      assert {:ok, application} = advance(ws, owner, application, :advance_to_interview)

      Application.put_env(:cgc_2046, Cgc2046.Mailer, adapter: FailingAdapter)

      assert :ok = deliver(@interview_signal, application)

      # 段位流转已提交（申请行是状态权威）：通知失败不回写业务状态
      assert Ash.get!(VolunteerApplication, application.id,
               tenant: ws.id,
               authorize?: false
             ).status == :interview

      assert_enqueued(
        worker: NotificationWorker,
        args: %{"template_key" => "volunteer_application_interview"}
      )
    end
  end

  describe "真实信号链（总线投递 + 同步消费）" do
    test "网申提交信号经总线投递 → 邮件 + 小程序通知（申请行终态已提交）", ctx do
      %{workspace: ws, applicant: applicant, cohort: cohort} = ctx

      # 停掉应用级订阅方：本用例经自己的订阅转发进程接收同一信号并同步驱动
      # deliver/2（sandbox owner），避免两个消费者对同一 claim 竞争
      :ok = Supervisor.terminate_child(Cgc2046.Supervisor, Subscriber)
      on_exit(fn -> {:ok, _pid} = Supervisor.restart_child(Cgc2046.Supervisor, Subscriber) end)

      test_pid = self()

      for pattern <- Subscriber.patterns() do
        assert {:ok, _sub_id, _monitor_ref, _forwarder_pid} =
                 JidoAdapter.subscribe(pattern, fn type, data ->
                   send(test_pid, {:bus_signal, %{type: type, data: data}})
                 end)
      end

      assert {:ok, application} = apply_for(ws, applicant, cohort, :event_moderator)

      assert application.status == :submitted

      job = signal_job(@submitted_signal)
      assert :ok = perform_job(SignalPublishWorker, job.args)

      data = await_bus_signal(@submitted_signal, job.args["data"])
      assert data["volunteer_application_id"] == application.id
      assert data["workspace_id"] == ws.id

      assert :ok = SignalSubscriber.deliver(Subscriber, %{type: @submitted_signal, data: data})

      email = assert_email()
      assert {_, @contact_email} = List.first(email.to)

      assert [notification] = enqueued_data("volunteer_application_submitted")
      assert notification["volunteer_application_id"] == application.id
      assert notification["identity_uid"] == "recruit-sub-openid"
    end
  end

  # --- 布置与断言助手 ---------------------------------------------------------

  defp deliver(signal_type, application) do
    SignalSubscriber.deliver(Subscriber, %{
      type: signal_type,
      data: signal_payload(application, signal_type)
    })
  end

  # 生产者 payload 形状（SignalEmitter 注入 workspace_id / idempotency_key；
  # 段位键为权威内容，订阅方以申请行回查）
  defp signal_payload(application, signal_type) do
    %{
      "volunteer_application_id" => application.id,
      "user_id" => application.user_id,
      "cohort_id" => application.cohort_id,
      "position" => to_string(application.position),
      "status" => to_string(application.status),
      "rejection_reason" => application.rejection_reason,
      "workspace_id" => application.workspace_id,
      "idempotency_key" => signal_type <> ":" <> application.id
    }
  end

  defp enqueued_data(template_key) do
    all_enqueued(worker: NotificationWorker)
    |> Enum.filter(&(&1.args["template_key"] == template_key))
    |> Enum.map(& &1.args)
  end

  defp claim_rows(signal_type) do
    SignalIdempotency
    |> Ash.Query.filter(signal_type == ^signal_type)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp signal_job(signal_type) do
    Enum.find(all_enqueued(worker: SignalPublishWorker), fn job ->
      job.args["signal_type"] == signal_type
    end) || flunk("no enqueued signal #{signal_type}")
  end

  defp assert_email(timeout \\ 1_000) do
    assert_receive {:email, email}, timeout
    email
  end

  # 总线投递是异步的（转发进程）：首投未在窗口内到达时按同一 payload 重投
  # （与 SignalPublishWorker 重试同构的恢复路径；至少一次语义下重投安全）
  defp await_bus_signal(signal_type, payload, attempts \\ 3)

  defp await_bus_signal(signal_type, payload, attempts) do
    receive do
      {:bus_signal, %{type: ^signal_type, data: data}} ->
        data
    after
      1_000 ->
        if attempts > 0 do
          assert :ok = JidoAdapter.publish(signal_type, payload)
          await_bus_signal(signal_type, payload, attempts - 1)
        else
          flunk("bus signal #{signal_type} not delivered within window")
        end
    end
  end

  defp beijing(nil), do: nil

  defp beijing(%DateTime{} = dt),
    do: dt |> DateTime.add(8 * 3600, :second) |> Calendar.strftime("%Y-%m-%d %H:%M")

  defp apply_for(workspace, actor, cohort, position) do
    VolunteerApplication
    |> Ash.Changeset.for_create(
      :create,
      %{
        cohort_id: cohort.id,
        position: position,
        city: "上海",
        heard_about_us: "公众号",
        has_internal_referrer: false,
        message: "希望参与"
      },
      tenant: workspace.id
    )
    |> Ash.create(tenant: workspace.id, actor: actor)
  end

  defp advance(workspace, actor, application, action, args \\ %{}) do
    application
    |> Ash.Changeset.for_update(action, args, tenant: workspace.id, actor: actor)
    |> Ash.update(tenant: workspace.id, actor: actor)
  end

  defp open_cohort(workspace, actor, name, attrs) do
    {:ok, cohort} =
      RecruitmentCohort
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(
          %{name: name, apply_deadline_at: DateTime.add(DateTime.utc_now(), 14, :day)},
          attrs
        ),
        tenant: workspace.id
      )
      |> Ash.create(tenant: workspace.id, actor: actor)

    {:ok, opened} =
      cohort
      |> Ash.Changeset.for_update(:open, %{}, tenant: workspace.id, actor: actor)
      |> Ash.update(tenant: workspace.id, actor: actor)

    opened
  end

  defp upsert_profile(workspace, actor, attrs) do
    ResumeProfile
    |> Ash.Changeset.for_create(:upsert, attrs, tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: actor)
  end

  defp register_phone_user(phone) do
    {:ok, user} =
      Cgc2046.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password_phone, %{
        phone: phone,
        password: "sup3r-secret-password"
      })
      |> Ash.create()

    user
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
end
