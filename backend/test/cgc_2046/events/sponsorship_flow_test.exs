defmodule Cgc2046.Events.SponsorshipFlowTest do
  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.{Event, Sponsorship, SponsorshipDelivery}
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Workflows.SignalSubscriber
  alias Cgc2046.Workers.SignalPublishWorker

  require Ash.Query

  @tier %{
    "id" => "6b8e3a5f-0000-4000-8000-000000000001",
    "name" => "冠名",
    "amount_suggestion" => 10_000,
    "benefits" => ["logo 展示位", "鸣谢页"],
    "exclusive" => true
  }

  @standard_tier %{
    "id" => "6b8e3a5f-0000-4000-8000-000000000002",
    "name" => "标准",
    "amount_suggestion" => 2_000,
    "benefits" => ["报名页露出"],
    "exclusive" => false
  }

  describe "意向提交（赞助段，pending 停住不生效权益）" do
    test "Event 级：合法意向落 pending，tier_name 冗余，approval_deadline 默认 7 天，无交付行" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{sponsorship_tiers: [@tier]})

      sponsor = Fixtures.register_user("sponsor-intent")

      {:ok, sponsorship} =
        create_sponsorship(%{level: :event, event_id: event.id, tier_id: @tier["id"]}, sponsor)

      assert sponsorship.status == :pending
      assert sponsorship.workspace_id == workspace.id
      assert sponsorship.tier_id == @tier["id"]
      assert sponsorship.tier_name == "冠名"
      assert sponsorship.approval_deadline != nil
      assert delivery_count(sponsorship.id) == 0
    end

    test "Workspace 级：target_workspace_id 即目标工作台，pending 停住" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin, %{sponsorship_tiers: [@standard_tier]})
      sponsor = Fixtures.register_user("sponsor-ws-intent")

      assert {:ok, sponsorship} =
               create_sponsorship(
                 %{level: :workspace, target_workspace_id: workspace.id},
                 sponsor
               )

      assert sponsorship.status == :pending
      assert sponsorship.workspace_id == workspace.id
      assert is_nil(sponsorship.event_id)
    end

    test "sponsorship_enabled=false 拒绝；deadline 已过拒绝；tier 不存在拒绝" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      disabled = EventFixtures.create_event(workspace, admin, %{sponsorship_enabled: false})

      deadline_passed =
        EventFixtures.create_event(workspace, admin, %{
          sponsorship_deadline: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      no_tier = EventFixtures.create_event(workspace, admin, %{sponsorship_tiers: [@tier]})
      sponsor = Fixtures.register_user("sponsor-guards")

      assert {:error, error} =
               create_sponsorship(%{level: :event, event_id: disabled.id}, sponsor)

      assert Exception.message(error) =~ "does not accept sponsorships"

      assert {:error, error} =
               create_sponsorship(%{level: :event, event_id: deadline_passed.id}, sponsor)

      assert Exception.message(error) =~ "does not accept sponsorships"

      assert {:error, error} =
               create_sponsorship(
                 %{
                   level: :event,
                   event_id: no_tier.id,
                   tier_id: "deadbeef-dead-dead-dead-deaddeafbeef"
                 },
                 sponsor
               )

      assert Exception.message(error) =~ "tier does not exist"
    end

    test "draft public event 拒绝（不泄露存在性）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()

      draft =
        Event
        |> Ash.Changeset.for_create(
          :create,
          %{
            title: "Draft Public Sponsor",
            enrollment_policy: :open,
            visibility: :public,
            sponsorship_enabled: true
          },
          tenant: workspace.id
        )
        |> Ash.create!(tenant: workspace.id, actor: owner)

      sponsor = Fixtures.register_user("sponsor-draft")

      assert {:error, error} = create_sponsorship(%{level: :event, event_id: draft.id}, sponsor)
      assert Exception.message(error) =~ "does not accept sponsorships"
    end

    test "event 级必须 event_id；workspace 级必须 target_workspace_id（GraphQL 入口）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      sponsor = Fixtures.register_user("sponsor-targets")

      assert {:error, error} = create_sponsorship(%{level: :event}, sponsor)
      assert Exception.message(error) =~ "event_id is required"

      assert {:error, error} = create_sponsorship(%{level: :workspace}, sponsor)
      assert Exception.message(error) =~ "target_workspace_id is required"

      assert {:ok, _} =
               create_sponsorship(
                 %{level: :workspace, target_workspace_id: workspace.id},
                 sponsor
               )
    end

    test "同一 sponsor 同一目标未终态不重复（唯一索引 + 预检）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      sponsor = Fixtures.register_user("sponsor-dup")

      assert {:ok, _} = create_sponsorship(%{level: :event, event_id: event.id}, sponsor)

      assert {:error, error} = create_sponsorship(%{level: :event, event_id: event.id}, sponsor)
      assert Exception.message(error) =~ "non-terminal sponsorship"
    end
  end

  describe "审批两段式（审批段）" do
    test "Event 级：Owner 审批通过 → active + 物化账本（行数 = benefits 数，独占标记随档位）" do
      {owner, workspace} = workspace_with_owner(%{sponsorship_tiers: [@tier]})
      event = EventFixtures.create_event(workspace, owner, %{sponsorship_tiers: [@tier]})
      sponsor = Fixtures.register_user("sponsor-approve")

      {:ok, pending} =
        create_sponsorship(%{level: :event, event_id: event.id, tier_id: @tier["id"]}, sponsor)

      assert {:ok, active} = approve(pending, owner)
      assert active.status == :active
      assert active.approved_by == owner.id
      assert active.approved_at != nil
      assert active.started_at != nil

      assert {:ok, deliveries} =
               SponsorshipDelivery
               |> Ash.Query.filter(sponsorship_id == ^active.id)
               |> Ash.read(authorize?: false)

      assert length(deliveries) == 2
      assert Enum.sort(Enum.map(deliveries, & &1.benefit)) == ["logo 展示位", "鸣谢页"]
      assert Enum.all?(deliveries, & &1.exclusive)
      assert Enum.all?(deliveries, &is_nil(&1.fulfilled_at))
    end

    test "Event 级：Admin 同样可审批（拍板 #4）" do
      {owner, workspace} = workspace_with_owner()
      admin_member = Fixtures.register_user("admin-approve-member")
      Fixtures.add_member(workspace, admin_member, [:admin])

      event = EventFixtures.create_event(workspace, owner)
      sponsor = Fixtures.register_user("sponsor-admin-approve")
      {:ok, pending} = create_sponsorship(%{level: :event, event_id: event.id}, sponsor)

      assert {:ok, active} = approve(pending, admin_member)
      assert active.status == :active
      assert active.approved_by == admin_member.id
    end

    test "Workspace 级：仅 Owner 可审批，Admin 被拒（拍板 #4）" do
      {owner, workspace} = workspace_with_owner(%{sponsorship_tiers: [@standard_tier]})
      admin_member = Fixtures.register_user("ws-approve-admin")
      Fixtures.add_member(workspace, admin_member, [:admin])
      sponsor = Fixtures.register_user("ws-sponsor-approve")

      assert {:ok, pending} =
               create_sponsorship(
                 %{
                   level: :workspace,
                   target_workspace_id: workspace.id,
                   tier_id: @standard_tier["id"]
                 },
                 sponsor
               )

      assert {:error, error} = approve(pending, admin_member)
      assert Exception.message(error) =~ "forbidden"

      assert {:ok, active} = approve(pending, owner)
      assert active.status == :active

      reloaded = Ash.get!(Sponsorship, pending.id, authorize?: false)
      assert reloaded.status == :active
      assert reloaded.approved_by == owner.id
    end

    test "reject 带 reason 落审计字段；终态不可再审批" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      sponsor = Fixtures.register_user("sponsor-reject")
      {:ok, pending} = create_sponsorship(%{level: :event, event_id: event.id}, sponsor)

      assert {:ok, rejected} =
               pending
               |> Ash.Changeset.for_update(:reject_sponsorship, %{rejection_reason: "物料不符合"})
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert rejected.status == :rejected
      assert rejected.approved_by == admin.id
      assert rejected.rejection_reason == "物料不符合"

      assert {:error, error} = approve(rejected, admin)
      assert Exception.message(error) =~ "already been processed"
    end

    test "重复 approved 幂等拒绝（already_processed），账本不重复物化" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin, %{sponsorship_tiers: [@standard_tier]})
      event = EventFixtures.create_event(workspace, admin, %{sponsorship_tiers: [@standard_tier]})
      sponsor = Fixtures.register_user("sponsor-repeat-approve")

      {:ok, pending} =
        create_sponsorship(
          %{level: :event, event_id: event.id, tier_id: @standard_tier["id"]},
          sponsor
        )

      assert {:ok, _} = approve(pending, admin)
      assert delivery_count(pending.id) == 1

      assert {:error, error} = approve(pending, admin)
      assert Exception.message(error) =~ "already been processed"
      assert delivery_count(pending.id) == 1
    end

    test "无档位赞助（tier 可选）激活不物化交付行" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      sponsor = Fixtures.register_user("sponsor-no-tier")
      {:ok, pending} = create_sponsorship(%{level: :event, event_id: event.id}, sponsor)

      assert {:ok, active} = approve(pending, admin)
      assert active.status == :active
      assert delivery_count(pending.id) == 0
    end
  end

  describe "独占权益位（D5）" do
    test "同一 Event 同一独占档位：第二个 active 被拒（顺序）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin, %{sponsorship_tiers: [@tier]})
      event = EventFixtures.create_event(workspace, admin, %{sponsorship_tiers: [@tier]})

      sponsor_a = Fixtures.register_user("exclusive-a")
      sponsor_b = Fixtures.register_user("exclusive-b")

      {:ok, pending_a} =
        create_sponsorship(%{level: :event, event_id: event.id, tier_id: @tier["id"]}, sponsor_a)

      {:ok, pending_b} =
        create_sponsorship(%{level: :event, event_id: event.id, tier_id: @tier["id"]}, sponsor_b)

      assert {:ok, active_a} = approve(pending_a, admin)
      assert active_a.status == :active

      assert {:error, error} = approve(pending_b, admin)
      assert Exception.message(error) =~ "exclusive sponsorship slot"

      assert Ash.get!(Sponsorship, pending_b.id, authorize?: false).status == :pending
    end

    test "非独占档位不冲突" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin, %{sponsorship_tiers: [@standard_tier]})
      event = EventFixtures.create_event(workspace, admin, %{sponsorship_tiers: [@standard_tier]})

      sponsor_a = Fixtures.register_user("non-exclusive-a")
      sponsor_b = Fixtures.register_user("non-exclusive-b")

      {:ok, pending_a} =
        create_sponsorship(
          %{level: :event, event_id: event.id, tier_id: @standard_tier["id"]},
          sponsor_a
        )

      {:ok, pending_b} =
        create_sponsorship(
          %{level: :event, event_id: event.id, tier_id: @standard_tier["id"]},
          sponsor_b
        )

      assert {:ok, _} = approve(pending_a, admin)
      assert {:ok, _} = approve(pending_b, admin)
    end
  end

  describe "履约账本核销" do
    test "核销落 proof_note + fulfilled_at；重复核销拒绝；非 Owner/Admin 不能核销" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin, %{sponsorship_tiers: [@standard_tier]})
      member = Fixtures.register_user("fulfill-member")
      Fixtures.add_member(workspace, member)

      event = EventFixtures.create_event(workspace, admin, %{sponsorship_tiers: [@standard_tier]})
      sponsor = Fixtures.register_user("fulfill-sponsor")

      {:ok, pending} =
        create_sponsorship(
          %{level: :event, event_id: event.id, tier_id: @standard_tier["id"]},
          sponsor
        )

      {:ok, _} = approve(pending, admin)

      [delivery] =
        SponsorshipDelivery
        |> Ash.Query.filter(sponsorship_id == ^pending.id)
        |> Ash.read!(authorize?: false)

      assert {:error, error} =
               delivery
               |> Ash.Changeset.for_update(:fulfill, %{proof_note: "物料已到位"})
               |> Ash.update(tenant: workspace.id, actor: member)

      assert Exception.message(error) =~ "forbidden"

      assert {:ok, fulfilled} =
               delivery
               |> Ash.Changeset.for_update(:fulfill, %{proof_note: "物料已到位"})
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert fulfilled.fulfilled_at != nil
      assert fulfilled.proof_note == "物料已到位"

      assert {:error, error} =
               fulfilled
               |> Ash.Changeset.for_update(:fulfill, %{proof_note: "again"})
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert Exception.message(error) =~ "already been fulfilled"
    end
  end

  describe "F7 审批超时" do
    test "过期 pending → expired 终态 + expired_at；过期后可重提（新行）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      sponsor = Fixtures.register_user("sponsor-expire")
      {:ok, pending} = create_sponsorship(%{level: :event, event_id: event.id}, sponsor)

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE sponsorships SET approval_deadline = NOW() - INTERVAL '1 minute' WHERE id = $1",
          [Ecto.UUID.dump!(pending.id)]
        )

      assert :ok = Cgc2046.Workers.ApprovalExpiryWorker.perform(%Oban.Job{})
      expired = Ash.get!(Sponsorship, pending.id, authorize?: false)
      assert expired.status == :expired
      refute is_nil(expired.expired_at)

      # 过期不否定申请：可重提（新行，唯一索引只锁 pending/active）
      assert {:ok, resubmitted} =
               create_sponsorship(%{level: :event, event_id: event.id}, sponsor)

      assert resubmitted.status == :pending
      assert resubmitted.id != expired.id
    end
  end

  describe "event.ended 订阅" do
    test "Event 级 active 转 ended；Workspace 级不受影响；重复投递不重复 ended（幂等）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin, %{sponsorship_tiers: [@standard_tier]})
      event = EventFixtures.create_event(workspace, admin, %{sponsorship_tiers: [@standard_tier]})

      event_sponsor = Fixtures.register_user("ended-event-sponsor")
      ws_sponsor = Fixtures.register_user("ended-ws-sponsor")

      {:ok, event_pending} =
        create_sponsorship(%{level: :event, event_id: event.id}, event_sponsor)

      {:ok, ws_pending} =
        create_sponsorship(%{level: :workspace, target_workspace_id: workspace.id}, ws_sponsor)

      {:ok, _} = approve(event_pending, admin)
      {:ok, _} = approve(ws_pending, admin)

      signal = %{
        type: "event.ended",
        data: %{
          "event_id" => event.id,
          "title" => event.title,
          "idempotency_key" => "event.ended:" <> event.id
        }
      }

      assert :ok = SignalSubscriber.deliver(Cgc2046.Events.SponsorshipEndedSubscriber, signal)

      assert Ash.get!(Sponsorship, event_pending.id, authorize?: false).status == :ended
      assert Ash.get!(Sponsorship, ws_pending.id, authorize?: false).status == :active

      # 重复投递：状态守卫幂等 + SignalIdempotency claim
      ended_at = Ash.get!(Sponsorship, event_pending.id, authorize?: false).ended_at
      assert :ok = SignalSubscriber.deliver(Cgc2046.Events.SponsorshipEndedSubscriber, signal)

      assert %{status: :ended, ended_at: ^ended_at} =
               Ash.get!(Sponsorship, event_pending.id, authorize?: false)

      # 骨架消费键（plan Q12）：生产者键 <> ":" <> 消费者短名
      claim_key = "event.ended:" <> event.id <> ":sponsorship_ended_subscriber"

      claim =
        Cgc2046.Workflows.SignalIdempotency
        |> Ash.Query.filter(signal_type == "event.ended" and idempotency_key == ^claim_key)
        |> Ash.read!(authorize?: false)

      assert length(claim) == 1
    end
  end

  describe "信号发布" do
    test "submitted/approved/rejected/active 信号按两段式入队，幂等键由 emitter 注入" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      # 事务内 outbox（plan 2026-08-14-003 Q6）：信号经 SignalPublishWorker job
      # 与实体终态同事务入队；幂等键 <type>:<record_id> 由 SignalEmitter 注入
      sponsor = Fixtures.register_user("sponsor-signals")
      {:ok, pending} = create_sponsorship(%{level: :event, event_id: event.id}, sponsor)

      assert_enqueued(
        worker: SignalPublishWorker,
        args: %{
          "signal_type" => "sponsorship.submitted",
          "data" => %{
            "sponsorship_id" => pending.id,
            "idempotency_key" => "sponsorship.submitted:" <> pending.id,
            "workspace_id" => workspace.id
          }
        }
      )

      {:ok, active} = approve(pending, admin)

      assert_enqueued(
        worker: SignalPublishWorker,
        args: %{
          "signal_type" => "sponsorship.approved",
          "data" => %{"sponsorship_id" => pending.id}
        }
      )

      assert_enqueued(
        worker: SignalPublishWorker,
        args: %{
          "signal_type" => "sponsorship.active",
          "data" => %{"idempotency_key" => "sponsorship.active:" <> pending.id}
        }
      )

      assert active.status == :active

      rejected_sponsor = Fixtures.register_user("sponsor-signals-rejected")
      {:ok, pending2} = create_sponsorship(%{level: :event, event_id: event.id}, rejected_sponsor)

      {:ok, _} =
        pending2
        |> Ash.Changeset.for_update(:reject_sponsorship, %{rejection_reason: "不符合"})
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert_enqueued(
        worker: SignalPublishWorker,
        args: %{
          "signal_type" => "sponsorship.rejected",
          "data" => %{"sponsorship_id" => pending2.id}
        }
      )
    end
  end

  describe "tiers 配置权限" do
    test "非 Owner/Admin 不能配 tiers（Event 与 Workspace 均拒绝）" do
      {owner, workspace} = workspace_with_owner()
      member = Fixtures.register_user("tiers-member")
      Fixtures.add_member(workspace, member)

      event = EventFixtures.create_event(workspace, owner)

      assert {:error, _} =
               event
               |> Ash.Changeset.for_update(:update, %{sponsorship_tiers: [@tier]})
               |> Ash.update(tenant: workspace.id, actor: member)

      assert {:error, _} =
               workspace
               |> Ash.Changeset.for_update(:update, %{sponsorship_tiers: [@tier]})
               |> Ash.update(actor: member)

      assert {:ok, _} =
               event
               |> Ash.Changeset.for_update(:update, %{sponsorship_tiers: [@tier]})
               |> Ash.update(tenant: workspace.id, actor: owner)

      assert Ash.get!(event.__struct__, event.id, authorize?: false).sponsorship_tiers == [@tier]
    end

    test "非法档位结构在更新时拒绝" do
      {owner, workspace} = workspace_with_owner()
      event = EventFixtures.create_event(workspace, owner)

      assert {:error, error} =
               event
               |> Ash.Changeset.for_update(:update, %{sponsorship_tiers: [%{"name" => "无 id"}]})
               |> Ash.update(tenant: workspace.id, actor: owner)

      assert Exception.message(error) =~ "tiers must be a list"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # Workspace 创建仅平台管理员可执行（policy）；Owner 角色经成员资格入座
  # （accounts_fixtures.workspace_with_member 同款布置纪律）。
  defp workspace_with_owner(attrs \\ %{}) do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin, attrs)
    owner = Fixtures.register_user("ws-owner")
    Fixtures.add_member(workspace, owner, [:owner])
    {owner, workspace}
  end

  defp create_sponsorship(attrs, sponsor) do
    attrs =
      Map.merge(
        %{sponsor_user_id: sponsor.id, company_name: "Acme", contact_email: sponsor.email},
        attrs
      )

    Sponsorship
    |> Ash.Changeset.for_create(:create_sponsorship, attrs)
    |> Ash.create(actor: sponsor)
  end

  defp approve(sponsorship, actor) do
    sponsorship
    |> Ash.Changeset.for_update(:approve_sponsorship, %{})
    |> Ash.update(tenant: sponsorship.workspace_id, actor: actor)
  end

  defp delivery_count(sponsorship_id) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        "SELECT count(*) FROM sponsorship_deliveries WHERE sponsorship_id = $1",
        [Ecto.UUID.dump!(sponsorship_id)]
      )

    count
  end
end
