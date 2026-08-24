defmodule Cgc2046.Events.SpeakerFlowTest do
  @moduledoc """
  E-4 #49 验收：Speaker 邀请 workflow 全链路。

  覆盖（issue #49 Acceptance + 任务验收清单）：

  - create → 着陆页 token 校验（card）→ accept → 材料产出（save_materials）
    → complete_speaking → completed；run 镜像 decision/materials 门控
  - decline 分支 → declined 终态（run failed）
  - 重复邀请（同 event+email 未终态）被拒；终态后可重邀
  - token 无效/已用/过期三种错误态（统一错误）；token 一次性（accept 后复用失效）
  - 权限：非 Owner/Admin 不能 create/list；卡片查询不泄露越权字段
  - 信号：speaker.accepted / declined / completed 走事务内 outbox
    （SignalPublishWorker）；订阅方经 SignalIdempotency 幂等去重

  关键断言是行为（状态转换、token 一次性、唯一性拒绝），不是 mock。
  """

  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  require Ash.Query

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Events.{SpeakerInvitation, SpeakerInvitations}
  alias Cgc2046.SpeakerSubscriber
  alias Cgc2046.Workflows.SignalIdempotency
  alias Cgc2046.Workflows.SignalSubscriber
  alias Cgc2046.Workflows.WorkflowRun
  alias Cgc2046.Workers.{NotificationWorker, SignalPublishWorker}

  describe "create_invitation" do
    test "Owner 创建邀请 → invited + workflow run waiting + 一次性明文 token（库中只存 hash）" do
      admin = Fixtures.platform_admin("spk-admin")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      assert {:ok, invitation, token} =
               SpeakerInvitation.issue(
                 %{
                   event_id: event.id,
                   speaker_name: "嘉宾甲",
                   speaker_email: "speaker-a@example.com",
                   topic: "Elixir 实战",
                   scheduled_at: DateTime.add(DateTime.utc_now(), 14, :day)
                 },
                 admin,
                 workspace.id
               )

      assert invitation.status == :invited
      assert invitation.workspace_id == workspace.id
      assert invitation.event_id == event.id
      assert invitation.invited_by == admin.id
      assert invitation.topic == "Elixir 实战"
      assert is_binary(token) and token != ""
      assert invitation.token_hash == SpeakerInvitation.hash_token(token)

      # 一个邀请 = 一个 run：start_run 直达 decision 门控（waiting）
      run = Ash.get!(WorkflowRun, invitation.workflow_run_id, authorize?: false)
      assert run.status == :waiting
      assert run.workspace_id == workspace.id
      assert run.input_snapshot["speaker_invitation_id"] == invitation.id

      # 明文不落库（token_hash 唯一列存 hash）
      assert raw_count("token_hash", token) == 0
    end

    test "同一 event + speaker_email 未终态重复邀请被拒；终态后可重邀" do
      admin = Fixtures.platform_admin("spk-dup")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      attrs = %{event_id: event.id, speaker_name: "嘉宾乙", speaker_email: "speaker-b@example.com"}

      assert {:ok, _first, token} = SpeakerInvitation.issue(attrs, admin, workspace.id)
      assert {:error, error} = SpeakerInvitation.issue(attrs, admin, workspace.id)
      assert Exception.message(error) =~ "already exists"

      # 婉拒后（终态）允许重邀；发出人不能自己 decline，由被邀请账号操作
      first =
        SpeakerInvitation
        |> Ash.Query.filter(token_hash == ^SpeakerInvitation.hash_token(token))
        |> Ash.read_one!(authorize?: false)

      speaker = Fixtures.register_user_with_email("speaker-b@example.com")
      assert {:ok, _declined} = decide(first, speaker, :decline_invitation, token)

      assert {:ok, _again, _new_token} = SpeakerInvitation.issue(attrs, admin, workspace.id)
    end

    test "speaker_email 归一化（trim + downcase）：大小写/空白变体视为同一邮箱，重复邀请被拒" do
      admin = Fixtures.platform_admin("spk-normalize")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      assert {:ok, invitation, _token} =
               SpeakerInvitation.issue(
                 %{
                   event_id: event.id,
                   speaker_name: "嘉宾丑",
                   speaker_email: "  Speaker-Case@Example.COM "
                 },
                 admin,
                 workspace.id
               )

      # 写入前归一：trim + downcase（唯一索引大小写敏感，归一后变体无法双邀）
      assert invitation.speaker_email == "speaker-case@example.com"

      assert {:error, error} =
               SpeakerInvitation.issue(
                 %{
                   event_id: event.id,
                   speaker_name: "嘉宾丑",
                   speaker_email: "speaker-case@example.com"
                 },
                 admin,
                 workspace.id
               )

      assert Exception.message(error) =~ "already exists"
    end

    test "普通成员不能创建（Forbidden）；event 归属与 tenant 不符被拒" do
      admin = Fixtures.platform_admin("spk-perm")
      workspace = Fixtures.create_workspace(admin)
      other_workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      member = Fixtures.register_user("spk-member")
      Fixtures.add_member(workspace, member)

      attrs = %{event_id: event.id, speaker_name: "嘉宾丙"}

      assert {:error, %Ash.Error.Forbidden{}} =
               SpeakerInvitation.issue(attrs, member, workspace.id)

      # actor 管理两个工作台：tenant（workspace）与 event 归属（other_workspace 传参）不符
      assert {:error, error} =
               SpeakerInvitation.issue(
                 Map.merge(attrs, %{workspace_id: other_workspace.id}),
                 admin,
                 workspace.id
               )

      assert Exception.message(error) =~ "does not belong to tenant"
    end

    test "closed 活动不可创建邀请" do
      admin = Fixtures.platform_admin("spk-closed")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      {:ok, _} =
        event
        |> Ash.Changeset.for_update(:close, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert {:error, error} =
               SpeakerInvitation.issue(
                 %{event_id: event.id, speaker_name: "嘉宾丁"},
                 admin,
                 workspace.id
               )

      assert Exception.message(error) =~ "closed or cancelled"
    end
  end

  describe "着陆页 token 校验（card 公开查询）" do
    setup %{} do
      admin = Fixtures.platform_admin("spk-card")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      {:ok, invitation, token} =
        SpeakerInvitation.issue(
          %{
            event_id: event.id,
            speaker_name: "嘉宾戊",
            speaker_email: "speaker-e@example.com",
            topic: "TypeScript 类型体操",
            scheduled_at: DateTime.add(DateTime.utc_now(), 7, :day)
          },
          admin,
          workspace.id
        )

      %{admin: admin, event: event, invitation: invitation, token: token}
    end

    test "有效 token 返回卡片：主题/时间 + Event 公开信息，不含越权字段", %{
      event: event,
      token: token
    } do
      assert {:ok, card} = SpeakerInvitations.card(token)

      assert card.status == "invited"
      assert card.topic == "TypeScript 类型体操"
      refute is_nil(card.scheduled_at)
      assert card.viewer_is_inviter == false

      assert card.event.id == event.id
      assert card.event.slug == event.slug
      assert card.event.title == event.title
      assert card.event.status == "open"

      # 不泄露越权字段：卡片只有状态/主题/时间 + Event 公开白名单 + viewer_is_inviter
      refute Map.has_key?(card, :speaker_email)
      refute Map.has_key?(card, :token_hash)
      refute Map.has_key?(card, :invited_by)
      refute Map.has_key?(card.event, :workspace_id)
      refute Map.has_key?(card.event, :capacity)
    end

    test "card(token, actor)：发出人 viewer_is_inviter=true，其他人/匿名为 false", %{
      admin: admin,
      token: token
    } do
      assert {:ok, %{viewer_is_inviter: true}} = SpeakerInvitations.card(token, admin)
      assert {:ok, %{viewer_is_inviter: false}} = SpeakerInvitations.card(token)
      other = Fixtures.register_user("spk-card-other")
      assert {:ok, %{viewer_is_inviter: false}} = SpeakerInvitations.card(token, other)
    end

    test "无效 token → 统一错误", %{} do
      assert {:error, :invalid_or_expired_token} = SpeakerInvitations.card("no-such-token")
    end

    test "已用 token（accept 后）→ 统一错误", %{invitation: invitation, token: token} do
      # 定向邀请（speaker-e@example.com）：accept 需账号匹配（§2.2 S2 拍板 #1）
      speaker = Fixtures.register_user_with_email("speaker-e@example.com")
      assert {:ok, _accepted} = decide(invitation, speaker, :accept_invitation, token)
      assert {:error, :invalid_or_expired_token} = SpeakerInvitations.card(token)
    end

    test "过期 token → 统一错误", %{event: event} do
      admin = Fixtures.platform_admin("spk-expired-card")
      # #49 收窄后 create_invitation 仅 Owner/Admin：本测试关注 token 过期错误，
      # 布置时给 admin 挂 Owner 成员资格（issue 需管理角色，过期判定在 action 内）
      workspace = Ash.get!(Cgc2046.Accounts.Workspace, event.workspace_id, authorize?: false)
      Fixtures.add_member(workspace, admin, [:owner])

      # 创建时未来有效期 + 裸 SQL 回拨（创建守卫拒绝 past expires_at，布置同款纪律）
      {:ok, invitation, expired_token} =
        SpeakerInvitation.issue(
          %{
            event_id: event.id,
            speaker_name: "嘉宾己",
            expires_at: DateTime.add(DateTime.utc_now(), 1, :hour)
          },
          admin,
          event.workspace_id
        )

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE speaker_invitations SET expires_at = NOW() - INTERVAL '1 hour' WHERE id = $1",
          [Ecto.UUID.dump!(invitation.id)]
        )

      assert {:error, :invalid_or_expired_token} = SpeakerInvitations.card(expired_token)
    end
  end

  describe "accept 链路（接受 → 材料产出 → 完成）" do
    setup %{} do
      admin = Fixtures.platform_admin("spk-accept")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      {:ok, invitation, token} =
        SpeakerInvitation.issue(
          %{event_id: event.id, speaker_name: "嘉宾庚", speaker_email: "speaker-g@example.com"},
          admin,
          workspace.id
        )

      # accept 双重校验（token + 账号匹配，§2.2 S2 拍板 #1）：speaker 须以被邀请邮箱注册
      speaker = Fixtures.register_user_with_email("speaker-g@example.com")

      %{admin: admin, invitation: invitation, token: token, speaker: speaker}
    end

    test "accept → accepted + 账号绑定 + run 推进 materials 门控 + outbox 信号", %{
      invitation: invitation,
      token: token,
      speaker: speaker
    } do
      assert {:ok, accepted} = decide(invitation, speaker, :accept_invitation, token)

      assert accepted.status == :accepted
      assert accepted.speaker_user_id == speaker.id
      assert accepted.accepted_by == speaker.id
      refute is_nil(accepted.accepted_at)

      # run 镜像：decision 放行 → materials 门控（仍 waiting）
      run = Ash.get!(WorkflowRun, invitation.workflow_run_id, authorize?: false)
      assert run.status == :waiting

      assert_enqueued(worker: SignalPublishWorker, args: %{"signal_type" => "speaker.accepted"})
    end

    test "token 一次性：accept 后复用失效（accept/decline 双拒绝）", %{
      invitation: invitation,
      token: token,
      speaker: speaker
    } do
      assert {:ok, _accepted} = decide(invitation, speaker, :accept_invitation, token)

      assert {:error, again_error} = decide(invitation, speaker, :accept_invitation, token)
      assert Exception.message(again_error) =~ "invalid, expired or already used"

      assert {:error, decline_error} = decide(invitation, speaker, :decline_invitation, token)
      assert Exception.message(decline_error) =~ "invalid, expired or already used"
    end

    test "过期 token 不能接受", %{admin: admin, invitation: invitation} do
      # 创建时未来有效期 + 裸 SQL 回拨（创建守卫拒绝 past expires_at）
      {:ok, expired, expired_token} =
        SpeakerInvitation.issue(
          %{
            event_id: invitation.event_id,
            speaker_name: "嘉宾辛",
            expires_at: DateTime.add(DateTime.utc_now(), 1, :hour)
          },
          admin,
          invitation.workspace_id
        )

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE speaker_invitations SET expires_at = NOW() - INTERVAL '1 hour' WHERE id = $1",
          [Ecto.UUID.dump!(expired.id)]
        )

      speaker = Fixtures.register_user("spk-expired-accept")
      assert {:error, error} = decide(expired, speaker, :accept_invitation, expired_token)
      assert Exception.message(error) =~ "invalid, expired or already used"
    end

    test "邮箱不匹配的账号 accept 被拒（:forbidden），邀请仍 invited、token 未消耗", %{
      invitation: invitation,
      token: token,
      speaker: speaker
    } do
      # 定向邀请（speaker-g@example.com）：token + 账号匹配双重校验（§2.2 S2 拍板 #1）
      mismatched = Fixtures.register_user("spk-mismatch")

      assert {:error, error} = decide(invitation, mismatched, :accept_invitation, token)
      assert Exception.message(error) =~ "only the invited speaker account"

      # 匹配校验先于条件 UPDATE 抢占：邀请仍 invited，token 未被消耗
      reloaded = Ash.get!(SpeakerInvitation, invitation.id, authorize?: false)
      assert reloaded.status == :invited
      assert is_nil(reloaded.speaker_user_id)

      # 正确账号随后可正常 accept
      assert {:ok, accepted} = decide(invitation, speaker, :accept_invitation, token)
      assert accepted.status == :accepted
      assert accepted.speaker_user_id == speaker.id
    end

    test "无 speaker_email 的邀请（手动转发链接）：发出人以外的登录账号可 accept", %{
      admin: admin,
      invitation: invitation
    } do
      {:ok, open_invitation, open_token} =
        SpeakerInvitation.issue(
          %{event_id: invitation.event_id, speaker_name: "嘉宾壬"},
          admin,
          invitation.workspace_id
        )

      anyone = Fixtures.register_user("spk-anyone")

      assert {:ok, accepted} = decide(open_invitation, anyone, :accept_invitation, open_token)
      assert accepted.status == :accepted
      assert accepted.speaker_user_id == anyone.id
    end

    test "发出人不能 accept/decline 自己发出的邀请；邀请仍 invited、token 未消耗", %{
      admin: admin,
      invitation: invitation
    } do
      {:ok, open_invitation, open_token} =
        SpeakerInvitation.issue(
          %{event_id: invitation.event_id, speaker_name: "嘉宾发出人"},
          admin,
          invitation.workspace_id
        )

      assert {:error, accept_error} =
               decide(open_invitation, admin, :accept_invitation, open_token)

      assert Exception.message(accept_error) =~ "sender cannot accept or decline"

      reloaded = Ash.get!(SpeakerInvitation, open_invitation.id, authorize?: false)
      assert reloaded.status == :invited
      assert is_nil(reloaded.speaker_user_id)

      assert {:error, decline_error} =
               decide(open_invitation, admin, :decline_invitation, open_token)

      assert Exception.message(decline_error) =~ "sender cannot accept or decline"

      reloaded = Ash.get!(SpeakerInvitation, open_invitation.id, authorize?: false)
      assert reloaded.status == :invited

      anyone = Fixtures.register_user("spk-after-inviter")
      assert {:ok, accepted} = decide(open_invitation, anyone, :accept_invitation, open_token)
      assert accepted.status == :accepted
    end

    test "发出人即使 speaker_email 匹配自己也不能 accept", %{
      admin: admin,
      invitation: invitation
    } do
      {:ok, self_invite, token} =
        SpeakerInvitation.issue(
          %{
            event_id: invitation.event_id,
            speaker_name: "我自己",
            speaker_email: to_string(admin.email)
          },
          admin,
          invitation.workspace_id
        )

      assert {:error, error} = decide(self_invite, admin, :accept_invitation, token)
      assert Exception.message(error) =~ "sender cannot accept or decline"

      reloaded = Ash.get!(SpeakerInvitation, self_invite.id, authorize?: false)
      assert reloaded.status == :invited
      assert is_nil(reloaded.speaker_user_id)
    end

    test "材料产出 → complete → completed + speaker.completed（幂等键）+ run succeeded", %{
      invitation: invitation,
      token: token,
      speaker: speaker
    } do
      assert {:ok, accepted} = decide(invitation, speaker, :accept_invitation, token)

      materials = %{"title" => "分享大纲", "link" => "https://example.com/slides"}

      assert {:ok, _saved} =
               accepted
               |> Ash.Changeset.for_update(:save_materials, %{materials: materials},
                 actor: speaker,
                 tenant: invitation.workspace_id
               )
               |> Ash.update(tenant: invitation.workspace_id, actor: speaker)

      run = Ash.get!(WorkflowRun, invitation.workflow_run_id, authorize?: false)
      assert run.facts["materials"] == materials

      assert {:ok, completed} =
               accepted
               |> Ash.Changeset.for_update(:complete_speaking, %{},
                 actor: speaker,
                 tenant: invitation.workspace_id
               )
               |> Ash.update(tenant: invitation.workspace_id, actor: speaker)

      assert completed.status == :completed
      refute is_nil(completed.completed_at)

      run = Ash.get!(WorkflowRun, invitation.workflow_run_id, authorize?: false)
      assert run.status == :succeeded

      assert_enqueued(worker: SignalPublishWorker, args: %{"signal_type" => "speaker.completed"})

      completed_job =
        all_enqueued(worker: SignalPublishWorker)
        |> Enum.find(&(&1.args["signal_type"] == "speaker.completed"))

      assert completed_job.args["data"]["idempotency_key"] ==
               "speaker.completed:" <> invitation.id
    end

    test "材料未产出时 complete 被拒（M1 校验）", %{
      invitation: invitation,
      token: token,
      speaker: speaker
    } do
      assert {:ok, accepted} = decide(invitation, speaker, :accept_invitation, token)

      assert {:error, error} =
               accepted
               |> Ash.Changeset.for_update(:complete_speaking, %{},
                 actor: speaker,
                 tenant: invitation.workspace_id
               )
               |> Ash.update(tenant: invitation.workspace_id, actor: speaker)

      assert Exception.message(error) =~ "materials"
      assert Ash.get!(SpeakerInvitation, invitation.id, authorize?: false).status == :accepted
    end

    test "非被邀请人（非 Owner/Admin）不能 save_materials / complete", %{
      invitation: invitation,
      token: token,
      speaker: speaker
    } do
      assert {:ok, accepted} = decide(invitation, speaker, :accept_invitation, token)
      outsider = Fixtures.register_user("spk-outsider")

      assert {:error, %Ash.Error.Forbidden{}} =
               accepted
               |> Ash.Changeset.for_update(:save_materials, %{materials: %{"a" => "b"}},
                 actor: outsider,
                 tenant: invitation.workspace_id
               )
               |> Ash.update(tenant: invitation.workspace_id, actor: outsider)

      assert {:error, %Ash.Error.Forbidden{}} =
               accepted
               |> Ash.Changeset.for_update(:complete_speaking, %{},
                 actor: outsider,
                 tenant: invitation.workspace_id
               )
               |> Ash.update(tenant: invitation.workspace_id, actor: outsider)
    end
  end

  describe "decline 链路" do
    test "decline → declined 终态 + run failed + outbox 信号；token 一次性", %{} do
      admin = Fixtures.platform_admin("spk-decline")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      {:ok, invitation, token} =
        SpeakerInvitation.issue(
          %{event_id: event.id, speaker_name: "嘉宾癸", speaker_email: "speaker-k@example.com"},
          admin,
          workspace.id
        )

      speaker = Fixtures.register_user("spk-speaker-k")

      assert {:ok, declined} = decide(invitation, speaker, :decline_invitation, token)

      assert declined.status == :declined
      refute is_nil(declined.declined_at)
      assert is_nil(declined.speaker_user_id)

      run = Ash.get!(WorkflowRun, invitation.workflow_run_id, authorize?: false)
      assert run.status == :failed

      assert_enqueued(worker: SignalPublishWorker, args: %{"signal_type" => "speaker.declined"})

      # decline 消耗 token：即使被邀请账号本人随后 accept 也统一拒绝
      # （非匹配账号此处会先命中 accept 的账号匹配门，单独用例覆盖）
      invited_account = Fixtures.register_user_with_email("speaker-k@example.com")

      assert {:error, error} = decide(invitation, invited_account, :accept_invitation, token)
      assert Exception.message(error) =~ "invalid, expired or already used"
    end

    test "decline 不需要账号匹配（token-only，与 accept 的不对称是刻意决策）", %{} do
      admin = Fixtures.platform_admin("spk-decline-anyone")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      {:ok, invitation, token} =
        SpeakerInvitation.issue(
          %{event_id: event.id, speaker_name: "嘉宾卯", speaker_email: "speaker-m@example.com"},
          admin,
          workspace.id
        )

      # 非匹配账号持有效 token 即可婉拒：不绑定账号、无劫持收益（见 decide/2 注释）
      non_matching = Fixtures.register_user("spk-decline-nonmatching")

      assert {:ok, declined} = decide(invitation, non_matching, :decline_invitation, token)

      assert declined.status == :declined
      refute is_nil(declined.declined_at)
      assert is_nil(declined.speaker_user_id)
    end
  end

  describe "邀请列表权限（Owner/Admin only）" do
    setup %{} do
      admin = Fixtures.platform_admin("spk-list")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      {:ok, invitation, _token} =
        SpeakerInvitation.issue(
          %{event_id: event.id, speaker_name: "嘉宾子", speaker_email: "speaker-z@example.com"},
          admin,
          workspace.id
        )

      %{admin: admin, workspace: workspace, event: event, invitation: invitation}
    end

    test "Owner 可 list 本 event 邀请", %{admin: admin, event: event, invitation: invitation} do
      assert {:ok, [listed]} = SpeakerInvitations.list_for_event(event.id, admin)
      assert listed.id == invitation.id
    end

    test "普通成员不能 list（forbidden）", %{workspace: workspace, event: event} do
      member = Fixtures.register_user("spk-list-member")
      Fixtures.add_member(workspace, member)

      assert {:error, :forbidden} = SpeakerInvitations.list_for_event(event.id, member)
    end

    test "其它工作台 Owner 不能 list", %{event: event} do
      # Workspace.create 仅平台管理员可调；另建工作台后把普通用户提为 owner，
      # 验证非平台管理员的跨工作台读取被 read policy 拒绝
      workspace_admin = Fixtures.platform_admin("spk-list-other-admin")
      other_workspace = Fixtures.create_workspace(workspace_admin)
      other_owner = Fixtures.register_user("spk-list-other")
      Fixtures.add_member(other_workspace, other_owner, [:owner])

      assert {:error, :forbidden} = SpeakerInvitations.list_for_event(event.id, other_owner)
    end
  end

  describe "订阅方：SpeakerSubscriber + SignalIdempotency（PR #121 复用）" do
    test "speaker.accepted → claim 幂等登记 + 通知入队；重复投递跳过", %{} do
      admin = Fixtures.platform_admin("spk-sub")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      insert_identity(admin.id, "spk-sub-admin-openid")

      {:ok, invitation, _token} =
        SpeakerInvitation.issue(
          %{event_id: event.id, speaker_name: "嘉宾丑", speaker_email: "speaker-c@example.com"},
          admin,
          workspace.id
        )

      # 订阅方回调直调（测试进程持有 sandbox 连接，确定性断言；总线异步投递
      # 机制本身由 enrollment 信号测试覆盖）
      data = %{
        "speaker_invitation_id" => invitation.id,
        "event_id" => event.id,
        "workspace_id" => workspace.id,
        "speaker_user_id" => nil,
        "status" => "accepted",
        "idempotency_key" => "speaker.accepted:" <> invitation.id
      }

      assert :ok =
               SignalSubscriber.deliver(SpeakerSubscriber, %{type: "speaker.accepted", data: data})

      assert_enqueued(worker: NotificationWorker, args: %{"template_key" => "speaker_accepted"})
      assert claim_rows("speaker.accepted") == 1

      # 同信号重复投递 → 幂等跳过（不再新增通知与 claim）
      assert :duplicate =
               SignalSubscriber.deliver(SpeakerSubscriber, %{type: "speaker.accepted", data: data})

      accepted_jobs =
        all_enqueued(worker: NotificationWorker)
        |> Enum.filter(&(&1.args["template_key"] == "speaker_accepted"))

      assert length(accepted_jobs) == 1
      assert claim_rows("speaker.accepted") == 1
    end

    test "speaker.completed → 通知 Owner/Admin + Speaker 本人（幂等键优先生产者携带）", %{} do
      admin = Fixtures.platform_admin("spk-sub-complete")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      # accept 需账号匹配（§2.2 S2 拍板 #1）：以被邀请邮箱注册 speaker
      speaker = Fixtures.register_user_with_email("speaker-y@example.com")

      insert_identity(admin.id, "spk-sub-complete-admin-openid")
      insert_identity(speaker.id, "spk-sub-complete-speaker-openid")

      {:ok, invitation, token} =
        SpeakerInvitation.issue(
          %{event_id: event.id, speaker_name: "嘉宾寅", speaker_email: "speaker-y@example.com"},
          admin,
          workspace.id
        )

      assert {:ok, accepted} = decide(invitation, speaker, :accept_invitation, token)

      data = %{
        "speaker_invitation_id" => invitation.id,
        "event_id" => event.id,
        "workspace_id" => workspace.id,
        "speaker_user_id" => accepted.speaker_user_id,
        "status" => "completed",
        "idempotency_key" => "speaker.completed:" <> invitation.id
      }

      assert :ok =
               SignalSubscriber.deliver(SpeakerSubscriber, %{
                 type: "speaker.completed",
                 data: data
               })

      completed_jobs =
        all_enqueued(worker: NotificationWorker)
        |> Enum.filter(&(&1.args["template_key"] == "speaker_completed"))

      # Owner/Admin（admin 一人）+ Speaker 本人 → 2 条（同模板，user_id 不同）
      assert length(completed_jobs) == 2
      user_ids = Enum.map(completed_jobs, & &1.args["user_id"]) |> Enum.sort()
      assert user_ids == Enum.sort([admin.id, speaker.id])
      assert claim_rows("speaker.completed") == 1
    end
  end

  describe "resend_invitation（重发 / 重新生成链接）" do
    test "重发 = 重新生成 token：旧链接即刻作废，新链接可决策（R6/R7/AE5）" do
      admin = Fixtures.platform_admin("spk-resend")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      {:ok, invitation, old_token} =
        SpeakerInvitation.issue(
          %{event_id: event.id, speaker_name: "嘉宾重发", speaker_email: "resend-a@example.com"},
          admin,
          workspace.id
        )

      assert {:ok, updated, new_token} = SpeakerInvitation.resend(invitation, admin)

      refute new_token == old_token
      assert updated.status == :invited
      assert updated.token_hash == SpeakerInvitation.hash_token(new_token)

      # 库层面旧 hash 不复存在（换 token 已持久化）
      reloaded = Ash.get!(SpeakerInvitation, invitation.id, authorize?: false)
      assert reloaded.token_hash == SpeakerInvitation.hash_token(new_token)

      # 旧 token → 统一无效态；新 token → 正常卡片
      assert {:error, :invalid_or_expired_token} = SpeakerInvitations.card(old_token)
      assert {:ok, %{status: "invited"}} = SpeakerInvitations.card(new_token)
    end

    test "无邮箱邀请重发：换 token 供复制转发（AE6，刷新丢链接的自救路径）" do
      admin = Fixtures.platform_admin("spk-resend-nomail")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      {:ok, invitation, old_token} =
        SpeakerInvitation.issue(
          %{event_id: event.id, speaker_name: "嘉宾手转"},
          admin,
          workspace.id
        )

      assert {:ok, updated, new_token} = SpeakerInvitation.resend(invitation, admin)
      refute new_token == old_token
      assert is_nil(updated.speaker_email)
      assert {:ok, _card} = SpeakerInvitations.card(new_token)
    end

    test "已接受（非 invited）不可重发 → 域错误（R6/AE7）" do
      admin = Fixtures.platform_admin("spk-resend-accepted")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      {:ok, invitation, token} =
        SpeakerInvitation.issue(
          %{event_id: event.id, speaker_name: "嘉宾已受", speaker_email: "resend-b@example.com"},
          admin,
          workspace.id
        )

      speaker = Fixtures.register_user_with_email("resend-b@example.com")
      assert {:ok, _accepted} = decide(invitation, speaker, :accept_invitation, token)

      assert {:error, error} = SpeakerInvitation.resend(invitation, admin)
      assert Exception.message(error) =~ "no longer pending"
    end

    test "普通成员不能重发（R9：与创建同权限）" do
      admin = Fixtures.platform_admin("spk-resend-member")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      member = Fixtures.register_user("spk-resend-member-user")
      Fixtures.add_member(workspace, member)

      {:ok, invitation, _token} =
        SpeakerInvitation.issue(
          %{event_id: event.id, speaker_name: "嘉宾成员测", speaker_email: "resend-c@example.com"},
          admin,
          workspace.id
        )

      assert {:error, %Ash.Error.Forbidden{}} = SpeakerInvitation.resend(invitation, member)
    end
  end

  test "并发 resend CAS（M1）：stale token_hash 的第二次重发被拒", %{} do
    admin = Fixtures.platform_admin("spk-resend-cas")
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin)

    {:ok, invitation, _token} =
      SpeakerInvitation.issue(
        %{event_id: event.id, speaker_name: "嘉宾CAS", speaker_email: "resend-cas@example.com"},
        admin,
        workspace.id
      )

    # 第一次重发成功（DB token_hash 已换新）
    assert {:ok, _updated, _new_token} = SpeakerInvitation.resend(invitation, admin)

    # 并发模拟：第二个调用方持 stale record（旧 token_hash）再发——CAS 使其
    # not_claimed，不得返回成功 + 死链邮件
    assert {:error, error} = SpeakerInvitation.resend(invitation, admin)
    assert Exception.message(error) =~ "no longer pending"

    # fresh read 后可正常重发（30s 冷却是前端层，后端不挡）
    fresh = Ash.get!(SpeakerInvitation, invitation.id, authorize?: false)
    assert {:ok, _u2, _t2} = SpeakerInvitation.resend(fresh, admin)
  end

  test "过期邀请重发即续期（HIGH 修订）：清空 expires_at，新链接即刻可决策", %{} do
    admin = Fixtures.platform_admin("spk-resend-expired")
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin)

    # 创建时未来有效期合法；过期 invited 只能来自时间流逝——裸 SQL 回拨布置
    # （force_open 同款纪律：布置而非被测对象）
    {:ok, invitation, _token} =
      SpeakerInvitation.issue(
        %{
          event_id: event.id,
          speaker_name: "嘉宾过期",
          speaker_email: "resend-exp@example.com",
          expires_at: DateTime.add(DateTime.utc_now(), 1, :hour)
        },
        admin,
        workspace.id
      )

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE speaker_invitations SET expires_at = NOW() - INTERVAL '1 hour' WHERE id = $1",
        [Ecto.UUID.dump!(invitation.id)]
      )

    # R6「一键自救」：拒绝重发会与未终态唯一索引叠加成死锁，故重发必须救活
    assert {:ok, updated, new_token} = SpeakerInvitation.resend(invitation, admin)
    assert is_nil(updated.expires_at)

    # 新链接即刻可用（card 无过期守卫拦截）；旧 token 作废
    assert {:ok, %{status: "invited"}} = SpeakerInvitations.card(new_token)
  end

  test "创建时拒绝已经过去的有效期（HIGH 修订）：不落地「生而即死」的邀请", %{} do
    admin = Fixtures.platform_admin("spk-exp-past")
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin)

    assert {:error, error} =
             SpeakerInvitation.issue(
               %{
                 event_id: event.id,
                 speaker_name: "嘉宾过去",
                 speaker_email: "exp-past@example.com",
                 expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
               },
               admin,
               workspace.id
             )

    assert Exception.message(error) =~ "expires_at must be in the future"
  end

  test "非法 speaker_email 创建被拒（MEDIUM）：不进入邮件投递面", %{} do
    admin = Fixtures.platform_admin("spk-email-fmt")
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin)

    # 逗号列表：旧正则接受，SendCloud 可能按逗号拆分 → 死信邀请
    for bad <- [
          "first,second@example.com",
          "a;b@example.com",
          "not-an-email",
          String.duplicate("x", 250) <> "@example.com"
        ] do
      assert {:error, error} =
               SpeakerInvitation.issue(
                 %{event_id: event.id, speaker_name: "嘉宾邮箱", speaker_email: bad},
                 admin,
                 workspace.id
               )

      assert Exception.message(error) =~ "valid email address", "should reject: #{bad}"
    end

    # 归一后合法的输入（首尾空白 + 大小写）不受影响
    assert {:ok, _inv, _tok} =
             SpeakerInvitation.issue(
               %{
                 event_id: event.id,
                 speaker_name: "嘉宾邮箱2",
                 speaker_email: "  Valid@Example.COM "
               },
               admin,
               workspace.id
             )
  end

  # --- helpers ---------------------------------------------------------------

  defp decide(invitation, actor, action, token) do
    invitation
    |> Ash.Changeset.for_update(action, %{token: token},
      actor: actor,
      tenant: invitation.workspace_id
    )
    |> Ash.update(tenant: invitation.workspace_id, actor: actor)
  end

  # 平台身份布置（E-2 async_signal_test 同款：register_user 只建账号不建
  # 平台身份；通知入队按 UserIdentity 精确投递）
  defp insert_identity(user_id, uid) do
    Cgc2046.Repo.query!(
      """
      INSERT INTO user_identities (id, provider, uid, user_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), 'wechat', $1, $2, NOW(), NOW())
      """,
      [uid, Ecto.UUID.dump!(user_id)]
    )
  end

  defp raw_count(column, value) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        "SELECT count(*) FROM speaker_invitations WHERE #{column} = $1",
        [value]
      )

    count
  end

  defp claim_rows(signal_type) do
    SignalIdempotency
    |> Ash.Query.filter(signal_type == ^signal_type)
    |> Ash.read!(authorize?: false)
    |> length()
  end
end
