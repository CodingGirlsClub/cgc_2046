defmodule Cgc2046.Events.SpeakerInvitationEmailTest do
  @moduledoc """
  邀请邮件（创建/重发即发，KD1）：内容完整性（R2）、中文单语（R3）、
  无邮箱邀请不发（R1/AE2）、邀请人无邮箱降级（R5/AE4）、投递失败只落
  日志/遥测不回写业务（R4/AE3）。

  async: false —— 临时改写 Mailer / web_base_url 应用环境（与
  PasswordResetTest 同纪律）；投递断言走 Swoosh Test adapter 的
  {:email, _} 消息（Task 的 parent = 测试进程）。
  """

  use Cgc2046.DataCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.{SpeakerInvitation, SpeakerInvitationEmail}
  alias Cgc2046.EventsFixtures, as: EventFixtures

  @telemetry_event [:cgc2046, :speaker_invitation, :send_email]

  defmodule FailingAdapter do
    use Swoosh.Adapter

    @impl true
    def deliver(_email, _config), do: {:error, :send_cloud_timeout}
  end

  setup do
    Application.put_env(:cgc_2046, :web_base_url, "http://localhost:3000")

    on_exit(fn ->
      Application.delete_env(:cgc_2046, Cgc2046.Mailer)
      Application.put_env(:cgc_2046, Cgc2046.Mailer, adapter: Swoosh.Adapters.Test)
      Application.put_env(:cgc_2046, :web_base_url, "http://localhost:3000")
    end)

    :ok
  end

  # platform_admin fixture 不设 display_name（nil），显式置名以断言 R2 的邀请人名字
  defp fixtures(prefix) do
    admin = Fixtures.platform_admin(prefix)

    admin =
      admin
      |> Ash.Changeset.for_update(:update_display_name, %{display_name: "组织者小王"})
      |> Ash.update!(actor: admin)

    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin, %{title: "Elixir 夜话"})
    %{admin: admin, workspace: workspace, event: event}
  end

  test "创建带邮箱邀请 → 中文邀请邮件含活动/工作台/邀请人/明细与着陆页链接（R1/R2/R3）" do
    %{admin: admin, workspace: workspace, event: event} = fixtures("spk-mail-create")

    scheduled_at = DateTime.add(DateTime.utc_now(), 14, :day) |> DateTime.truncate(:second)

    assert {:ok, _invitation, token} =
             SpeakerInvitation.issue(
               %{
                 event_id: event.id,
                 speaker_name: "嘉宾邮件",
                 speaker_email: "mail-speaker@example.com",
                 topic: "Phoenix LiveView",
                 scheduled_at: scheduled_at,
                 note: "请提前准备 slides"
               },
               admin,
               workspace.id
             )

    assert_receive {:email, email}, 1_000

    assert {_, "mail-speaker@example.com"} = List.first(email.to)
    assert email.from == {"CGC 2046", "no-reply@example.com"}
    assert email.subject == "邀请你在「Elixir 夜话」做分享"

    local = DateTime.add(scheduled_at, 8 * 3600, :second)

    for expected <- [
          "Elixir 夜话",
          workspace.name,
          "组织者小王",
          to_string(admin.email),
          "Phoenix LiveView",
          Calendar.strftime(local, "%Y-%m-%d %H:%M"),
          "请提前准备 slides",
          "/events/#{event.slug}/speaker-invite/#{token}"
        ] do
      assert email.html_body =~ expected
    end
  end

  test "创建未填邮箱 → 不发邮件，保留手动转发语义（R1/AE2）" do
    %{admin: admin, workspace: workspace, event: event} = fixtures("spk-mail-none")

    assert {:ok, _invitation, _token} =
             SpeakerInvitation.issue(
               %{event_id: event.id, speaker_name: "嘉宾无邮箱"},
               admin,
               workspace.id
             )

    refute_receive {:email, _email}, 100
  end

  test "重发 → 新 token 再发一封，正文只含新链接（R8/AE5）" do
    %{admin: admin, workspace: workspace, event: event} = fixtures("spk-mail-resend")

    {:ok, invitation, first_token} =
      SpeakerInvitation.issue(
        %{event_id: event.id, speaker_name: "嘉宾重发", speaker_email: "mail-resend@example.com"},
        admin,
        workspace.id
      )

    assert_receive {:email, _first}, 1_000

    assert {:ok, _updated, second_token} = SpeakerInvitation.resend(invitation, admin)
    refute second_token == first_token

    assert_receive {:email, second}, 1_000
    assert second.html_body =~ second_token
    refute second.html_body =~ first_token
  end

  test "deliver 直调：邀请人无邮箱只显名字（R5/AE4）；正文插值 HTML 转义" do
    fields = %{
      to: "pure@example.com",
      speaker_name: "嘉宾纯",
      inviter_name: "无邮箱组织者",
      inviter_email: nil,
      event_title: "技术沙龙 <环节>",
      event_slug: "demo-event",
      workspace_name: "Workspace X",
      topic: "<img src=x onerror=alert(1)>",
      scheduled_at: nil,
      note: nil
    }

    assert :ok = SpeakerInvitationEmail.deliver(fields, "tok_pure123")

    assert_receive {:email, email}, 1_000
    assert email.html_body =~ "无邮箱组织者"
    assert email.html_body =~ "/events/demo-event/speaker-invite/tok_pure123"
    # R5：邀请人无邮箱行
    refute email.html_body =~ "邀请人邮箱"
    # XSS：插值全部转义，无原始标签 / 裸 % 泄漏
    refute email.html_body =~ "<img"
    refute email.html_body =~ "<环节>"
    refute email.html_body =~ "%"
  end

  test "投递失败：吞掉异常，遥测只含掩码邮箱与原因（R4/AE3）" do
    %{admin: admin, workspace: workspace, event: event} = fixtures("spk-mail-fail")
    test_pid = self()
    handler_id = "speaker-invitation-email-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        @telemetry_event,
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:spk_telemetry, measurements, metadata})
        end,
        nil
      )

    Application.put_env(:cgc_2046, Cgc2046.Mailer, adapter: FailingAdapter)

    try do
      assert {:ok, _invitation, token} =
               SpeakerInvitation.issue(
                 %{
                   event_id: event.id,
                   speaker_name: "嘉宾失败",
                   speaker_email: "fail-speaker@example.com"
                 },
                 admin,
                 workspace.id
               )

      # 邀请创建不受发送失败影响（R4）
      assert is_binary(token) and token != ""

      assert_receive {:spk_telemetry, %{count: 1}, metadata}, 1_000
      assert metadata.reason == :send_cloud_timeout
      assert metadata.email == "f***@example.com"
      refute inspect(metadata) =~ "fail-speaker"
      refute inspect(metadata) =~ token
    after
      :telemetry.detach(handler_id)
      Application.delete_env(:cgc_2046, Cgc2046.Mailer)
    end
  end
end
