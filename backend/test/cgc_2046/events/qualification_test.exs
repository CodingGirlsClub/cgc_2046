defmodule Cgc2046.Events.QualificationTest do
  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Events.{Event, Qualification}
  alias Cgc2046.EventsFixtures

  test "event without minimum participants is not applicable" do
    assert Qualification.qualify(%Event{min_participants: nil}) == :not_applicable
  end

  test "qualification snapshots confirmed enrollments once" do
    admin = Fixtures.platform_admin("qualification-test")
    workspace = Fixtures.create_workspace(admin)
    event = EventsFixtures.create_event(workspace, admin, %{min_participants: 2})
    learner = Fixtures.register_user("qualification-learner")

    assert {:ok, enrollment} =
             Enrollment
             |> Ash.Changeset.for_create(:create_enrollment, %{
               event_id: event.id,
               user_id: learner.id
             })
             |> Ash.create(tenant: workspace.id, actor: learner)

    assert enrollment.status == :confirmed

    Cgc2046.Repo.query!(
      "UPDATE events SET registration_deadline = NOW() - INTERVAL '1 hour' WHERE id = $1",
      [Ecto.UUID.dump!(event.id)]
    )

    assert {:ok, :underfilled, _recipients, 1} = Qualification.qualify(event)
    assert :skip = Qualification.qualify(event)
    assert Ash.get!(Event, event.id, authorize?: false).qualification_status == :underfilled
  end

  # ── #585 R2：无截止场以 starts_at - 72h 兜底判定 ────────────────────────

  test "无截止场以 starts_at - 72h 为锚点：过点落 underfilled，二次扫描 skip" do
    admin = Fixtures.platform_admin("qual-fallback")
    workspace = Fixtures.create_workspace(admin)

    event =
      EventsFixtures.create_event(workspace, admin, %{
        min_participants: 2,
        registration_deadline: nil,
        starts_at: DateTime.add(DateTime.utc_now(), 1, :day)
      })

    learner = Fixtures.register_user("qual-fallback-learner")

    assert {:ok, _} =
             Enrollment
             |> Ash.Changeset.for_create(:create_enrollment, %{
               event_id: event.id,
               user_id: learner.id
             })
             |> Ash.create(tenant: workspace.id, actor: learner)

    assert {:ok, :underfilled, _recipients, 1} = Qualification.qualify(event)
    assert :skip = Qualification.qualify(event)
    assert Ash.get!(Event, event.id, authorize?: false).qualification_status == :underfilled
  end

  test "兜底锚点未到点（starts_at - 72h 在未来）→ skip 且状态不动" do
    admin = Fixtures.platform_admin("qual-fallback-future")
    workspace = Fixtures.create_workspace(admin)

    event =
      EventsFixtures.create_event(workspace, admin, %{
        min_participants: 2,
        registration_deadline: nil,
        starts_at: DateTime.add(DateTime.utc_now(), 5, :day)
      })

    assert :skip = Qualification.qualify(event)
    assert Ash.get!(Event, event.id, authorize?: false).qualification_status == :pending
  end

  test "显式截止恒胜兜底：deadline 未来 + starts_at 已入 72h 窗 → 不提前判定" do
    admin = Fixtures.platform_admin("qual-precedence")
    workspace = Fixtures.create_workspace(admin)

    event =
      EventsFixtures.create_event(workspace, admin, %{
        min_participants: 2,
        registration_deadline: DateTime.add(DateTime.utc_now(), 7, :day),
        starts_at: DateTime.add(DateTime.utc_now(), 1, :hour)
      })

    assert :skip = Qualification.qualify(event)
    assert Ash.get!(Event, event.id, authorize?: false).qualification_status == :pending
  end

  test "deadline 与 starts_at 双 nil → 显式 skip（永不判定，接受语义）" do
    admin = Fixtures.platform_admin("qual-both-nil")
    workspace = Fixtures.create_workspace(admin)

    event =
      EventsFixtures.create_event(workspace, admin, %{
        min_participants: 2,
        registration_deadline: nil
      })

    assert :skip = Qualification.qualify(event)
  end

  # ── #585 R1：管理侧收件人（Owner/Admin，普通成员排除） ──────────────────

  test "underfilled 结局：Owner/Admin 收 event_qualification_manager，普通成员不收" do
    admin = Fixtures.platform_admin("qual-manager-underfilled")
    workspace = Fixtures.create_workspace(admin)
    co_admin = Fixtures.register_user("qual-manager-co-admin")
    Fixtures.add_member(workspace, co_admin, ["admin"])
    member = Fixtures.register_user("qual-manager-member")
    Fixtures.add_member(workspace, member)
    insert_identity(admin.id, :wechat, "qual-manager-underfilled-owner")
    insert_identity(co_admin.id, :wechat, "qual-manager-underfilled-admin")

    event =
      EventsFixtures.create_event(workspace, admin, %{
        min_participants: 2,
        registration_deadline: nil,
        starts_at: DateTime.add(DateTime.utc_now(), 1, :day)
      })

    learner = Fixtures.register_user("qual-manager-underfilled-learner")

    assert {:ok, _} =
             Enrollment
             |> Ash.Changeset.for_create(:create_enrollment, %{
               event_id: event.id,
               user_id: learner.id
             })
             |> Ash.create(tenant: workspace.id, actor: learner)

    assert {:ok, :underfilled, _recipients, 1} = Qualification.qualify(event)

    rows = delivery_rows(event.id, "event_qualification_manager")
    assert MapSet.new(rows, & &1.user_id) == MapSet.new([admin.id, co_admin.id])
    assert Enum.all?(rows, &(&1.data["outcome"] == "underfilled"))
  end

  test "confirmed 结局：管理侧收 event_qualification_manager（outcome=confirmed）" do
    admin = Fixtures.platform_admin("qual-manager-confirmed")
    workspace = Fixtures.create_workspace(admin)
    insert_identity(admin.id, :wechat, "qual-manager-confirmed-owner")

    event =
      EventsFixtures.create_event(workspace, admin, %{
        min_participants: 1,
        registration_deadline: nil,
        starts_at: DateTime.add(DateTime.utc_now(), 1, :day)
      })

    learner = Fixtures.register_user("qual-manager-confirmed-learner")

    assert {:ok, _} =
             Enrollment
             |> Ash.Changeset.for_create(:create_enrollment, %{
               event_id: event.id,
               user_id: learner.id
             })
             |> Ash.create(tenant: workspace.id, actor: learner)

    assert {:ok, :confirmed, _recipients, 1} = Qualification.qualify(event)

    rows = delivery_rows(event.id, "event_qualification_manager")
    assert MapSet.new(rows, & &1.user_id) == MapSet.new([admin.id])
    assert Enum.all?(rows, &(&1.data["outcome"] == "confirmed"))
  end

  test "双角色（Owner 兼报名者）两条各达：独立幂等基键，重复扫描不重复" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    insert_identity(owner.id, :wechat, "qual-dual-role-owner")

    event =
      EventsFixtures.create_event(workspace, owner, %{
        min_participants: 1,
        registration_deadline: nil,
        starts_at: DateTime.add(DateTime.utc_now(), 1, :day)
      })

    assert {:ok, _} =
             Enrollment
             |> Ash.Changeset.for_create(:create_enrollment, %{
               event_id: event.id,
               user_id: owner.id
             })
             |> Ash.create(tenant: workspace.id, actor: owner)

    assert {:ok, :confirmed, _recipients, 1} = Qualification.qualify(event)

    # 双角色两条：参与者文案 + 管理者文案（共享基键会吞掉管理行）
    assert length(delivery_rows(event.id, "event_qualification_confirmed")) == 1
    assert length(delivery_rows(event.id, "event_qualification_manager")) == 1

    # 重复扫描 CAS skip：outbox 不再新增任何键的行
    assert :skip = Qualification.qualify(event)
    assert length(delivery_rows(event.id, "event_qualification_confirmed")) == 1
    assert length(delivery_rows(event.id, "event_qualification_manager")) == 1
  end

  defp insert_identity(user_id, provider, uid) do
    Cgc2046.Repo.query!(
      """
      INSERT INTO user_identities (id, provider, uid, user_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $2, $3, NOW(), NOW())
      """,
      [to_string(provider), uid, Ecto.UUID.dump!(user_id)]
    )
  end

  defp delivery_rows(event_id, template_key) do
    Cgc2046.Notifications.NotificationDelivery
    |> Ash.Query.filter(template_key == ^template_key)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.job_meta["event_id"] == event_id))
  end
end
