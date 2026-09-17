defmodule Cgc2046.Events.EventDraftDeletionTest do
  @moduledoc """
  #676 draft 活动删除（`Event :delete`，ADR-0015）：

  - draft 删除成功：行消失、**同 slug 立即可复用**、主理人行（event_moderators）
    随 FK `on_delete: delete_all` 级联消失
  - 非 draft（open）拒绝：`cannot delete from status=open`，行不动
  - 域权限收窄：admin ❌（Forbidden）；平台管理员 ✅（非成员亦放行）
  - #688 级联完备性：讲者邀请 run 同事务收口（非终态 → cancelled 留痕、终态
    不动、他台 run 不受影响、收口失败整体回滚）；名额账本行一并删除
  """
  # async: false：#688 原子性用例走 unboxed 双连接并发交错（shared sandbox
  # 才能让 Task 进程看到布置的真实提交——course_draft_deletion_test 并发
  # 用例同款纪律）。
  use Cgc2046.DataCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.CapacityLedger
  alias Cgc2046.Events.{Event, EventModerator, Moderators, SpeakerInvitation}
  alias Cgc2046.Repo
  alias Cgc2046.Workflows.WorkflowRun

  require Ash.Query

  defp draft_event(workspace, actor, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{title: "待删草稿活动", slug: "issue676-draft-event"},
        attrs
      )

    Event
    |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: actor)
  end

  defp launch(event, actor) do
    event
    |> Ash.Changeset.for_update(:launch, %{}, tenant: event.workspace_id)
    |> Ash.update!(tenant: event.workspace_id, actor: actor)
  end

  defp delete(event, actor) do
    event
    |> Ash.Changeset.for_destroy(:delete, %{}, tenant: event.workspace_id)
    |> Ash.destroy(tenant: event.workspace_id, actor: actor)
  end

  defp moderator_rows(event, workspace_id) do
    EventModerator
    |> Ash.Query.filter(event_id == ^event.id)
    |> Ash.read!(authorize?: false, tenant: workspace_id)
  end

  # 行已删除：Ash.get 对不存在的主键回 NotFound（不是 {:ok, nil}）
  defp assert_deleted(id) do
    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
             Ash.get(Event, id, authorize?: false)
  end

  test "draft 删除：行消失、slug 复用、主理人行级联消失" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    event = draft_event(workspace, owner)

    moderator = Fixtures.register_user("issue676-del-mod")
    Fixtures.add_member(workspace, moderator, [:learner])
    {:ok, _} = Moderators.assign(event.id, workspace.id, moderator.id, owner)

    # 创建者（owner）自动入座 + 显式指派的 moderator
    assert length(moderator_rows(event, workspace.id)) == 2

    assert :ok = delete(event, owner)

    assert_deleted(event.id)
    assert moderator_rows(event, workspace.id) == []

    assert {:ok, recreated} =
             Event
             |> Ash.Changeset.for_create(
               :create,
               %{title: "重建活动", slug: "issue676-draft-event"},
               tenant: workspace.id
             )
             |> Ash.create(tenant: workspace.id, actor: owner)

    assert recreated.slug == "issue676-draft-event"
  end

  test "open 活动拒绝删除（cannot delete from status=open），行不动" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    event = draft_event(workspace, owner)

    assert %{status: :open} = open = launch(event, owner)

    assert {:error, error} = delete(open, owner)
    assert Exception.message(error) =~ "cannot delete from status=open"

    assert {:ok, %Event{status: :open}} = Ash.get(Event, event.id, authorize?: false)
  end

  test "域权限：admin ❌（Forbidden）、非成员平台管理员 ✅" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()

    admin_member = Fixtures.register_user("issue676-ev-admin")
    Fixtures.add_member(workspace, admin_member, [:admin])

    admin_event = draft_event(workspace, owner, %{slug: "issue676-admin-event"})

    assert {:error, %Ash.Error.Forbidden{}} = delete(admin_event, admin_member)
    assert {:ok, %Event{status: :draft}} = Ash.get(Event, admin_event.id, authorize?: false)

    platform = Fixtures.platform_admin("issue676-ev-platform")
    platform_event = draft_event(workspace, owner, %{slug: "issue676-platform-event"})

    assert :ok = delete(platform_event, platform)
    assert_deleted(platform_event.id)
  end

  # ── #688 级联完备性 ─────────────────────────────────────────────────────────

  test "#688 draft + 讲者邀请删除：邀请行级联消失、非终态 run 收口 cancelled、终态 run 不动" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    event = draft_event(workspace, owner, %{slug: "issue688-spk-event"})

    # A：已接受（run 仍非终态——waiting @ materials 门控）
    {:ok, invitation_a, token_a} =
      SpeakerInvitation.issue(
        %{event_id: event.id, speaker_name: "讲者甲", speaker_email: "spk-a-688@example.com"},
        owner,
        workspace.id
      )

    speaker_a = Fixtures.register_user_with_email("spk-a-688@example.com")

    assert {:ok, %SpeakerInvitation{status: :accepted}} =
             SpeakerInvitation.decide(speaker_a, token_a, :accept_invitation)

    run_a = Ash.get!(WorkflowRun, invitation_a.workflow_run_id, authorize?: false)
    assert run_a.status == :waiting

    # B：已婉拒（run failed 终态——收口不得触碰的负例）
    {:ok, invitation_b, token_b} =
      SpeakerInvitation.issue(
        %{event_id: event.id, speaker_name: "讲者乙", speaker_email: "spk-b-688@example.com"},
        owner,
        workspace.id
      )

    speaker_b = Fixtures.register_user_with_email("spk-b-688@example.com")
    assert {:ok, _} = SpeakerInvitation.decide(speaker_b, token_b, :decline_invitation)

    run_b = Ash.get!(WorkflowRun, invitation_b.workflow_run_id, authorize?: false)
    assert run_b.status == :failed

    assert :ok = delete(event, owner)

    assert_deleted(event.id)

    # 邀请行随 FK delete_all 级联消失（讲者链接即刻 404——摘要已披露）
    invitations =
      SpeakerInvitation
      |> Ash.Query.filter(event_id == ^event.id)
      |> Ash.read!(authorize?: false, tenant: workspace.id)

    assert invitations == []

    # 非终态 run 收口 cancelled（finished_at 落位）；facts 留痕语义——不清
    cancelled = Ash.get!(WorkflowRun, run_a.id, authorize?: false)
    assert cancelled.status == :cancelled
    assert cancelled.finished_at

    # 终态 run 不动
    assert Ash.get!(WorkflowRun, run_b.id, authorize?: false).status == :failed
  end

  test "#688 租户隔离：他台讲者 run 不受本台活动删除影响" do
    %{owner: owner_a, workspace: workspace_a} = Fixtures.workspace_with_member()
    %{owner: owner_b, workspace: workspace_b} = Fixtures.workspace_with_member()

    event_a = draft_event(workspace_a, owner_a, %{slug: "issue688-tenant-a"})
    event_b = draft_event(workspace_b, owner_b, %{slug: "issue688-tenant-b"})

    # 两台各一个非终态讲者 run（同形：waiting @ decision 门控）
    {:ok, inv_a, _} =
      SpeakerInvitation.issue(
        %{event_id: event_a.id, speaker_name: "台A讲者", speaker_email: "ten-a-688@example.com"},
        owner_a,
        workspace_a.id
      )

    {:ok, inv_b, _} =
      SpeakerInvitation.issue(
        %{event_id: event_b.id, speaker_name: "台B讲者", speaker_email: "ten-b-688@example.com"},
        owner_b,
        workspace_b.id
      )

    run_a = Ash.get!(WorkflowRun, inv_a.workflow_run_id, authorize?: false)
    run_b = Ash.get!(WorkflowRun, inv_b.workflow_run_id, authorize?: false)
    assert run_a.status == :waiting
    assert run_b.status == :waiting

    assert :ok = delete(event_a, owner_a)

    # 本台收口；他台 run 原样 waiting、活动行仍在
    assert Ash.get!(WorkflowRun, run_a.id, authorize?: false).status == :cancelled
    assert Ash.get!(WorkflowRun, run_b.id, authorize?: false).status == :waiting
    assert {:ok, %Event{status: :draft}} = Ash.get(Event, event_b.id, authorize?: false)
  end

  test "#688 名额账本行随 draft 删除一并消失" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    event = draft_event(workspace, owner, %{slug: "issue688-ledger-event"})

    # 布置（非被测对象）：直连建行——真实建行路径之一（Initiative 规则传播同款
    # 入口 sync_offering_cache；capacity_changed 信号路径异步，不属于被测级联）
    :ok =
      CapacityLedger.sync_offering_cache(%{
        kind: :event,
        offering_id: event.id,
        workspace_id: workspace.id,
        status: :draft,
        capacity: 30
      })

    assert {:ok, _} = CapacityLedger.fetch_by_offering(:event, event.id)

    assert :ok = delete(event, owner)

    assert {:error, :not_found} = CapacityLedger.fetch_by_offering(:event, event.id)
  end

  # ── #688 原子性（真实并发失败注入，不打桩；course_draft_deletion_test 并发
  # 用例同款 unboxed 纪律：sandbox 未提交数据对 unboxed 连接不可见，须真实提交
  # + 显式收尾）────────────────────────────────────────────────────────────────

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  defp cleanup_atomic_on_exit(workspace_id, users, event_id, run_id) do
    on_exit(fn ->
      unboxed(fn ->
        # 讲者 run 无 FK 指向 events（#688 的缺口本体）——按 id 逐一显式清；
        # 本用例无 Oban job（邀请创建不发信号，删除事务整体回滚连带 outbox）
        Repo.query!("DELETE FROM events WHERE id = $1", [Repo.uuid!(event_id)])
        Repo.query!("DELETE FROM workflow_runs WHERE id = $1", [Repo.uuid!(run_id)])

        Repo.query!("DELETE FROM workflow_definitions WHERE workspace_id = $1", [
          Repo.uuid!(workspace_id)
        ])

        Repo.query!(
          "DELETE FROM admin_action_logs WHERE target_type = 'workspace' AND target_id = $1",
          [Repo.uuid!(workspace_id)]
        )

        Repo.query!(
          "DELETE FROM membership_roles WHERE membership_id IN " <>
            "(SELECT id FROM workspace_memberships WHERE workspace_id = $1)",
          [Repo.uuid!(workspace_id)]
        )

        Repo.query!("DELETE FROM workspace_memberships WHERE workspace_id = $1", [
          Repo.uuid!(workspace_id)
        ])

        Repo.query!("DELETE FROM workspaces WHERE id = $1", [Repo.uuid!(workspace_id)])

        Enum.each(users, fn user ->
          Repo.query!("DELETE FROM users WHERE id = $1", [Repo.uuid!(user.id)])
        end)
      end)
    end)
  end

  test "#688 原子性：收口失败整体回滚——event 行仍在、run 状态不变" do
    {owner, workspace, event, run_id} =
      unboxed(fn ->
        owner = Fixtures.platform_admin("issue688-atomic-owner")
        workspace = Fixtures.create_workspace(owner)
        event = draft_event(workspace, owner, %{slug: "issue688-atomic-event"})

        {:ok, invitation, _} =
          SpeakerInvitation.issue(
            %{event_id: event.id, speaker_name: "冲突讲者", speaker_email: "atomic-688@example.com"},
            owner,
            workspace.id
          )

        assert Ash.get!(WorkflowRun, invitation.workflow_run_id, authorize?: false).status ==
                 :waiting

        {owner, workspace, event, invitation.workflow_run_id}
      end)

    cleanup_atomic_on_exit(workspace.id, [owner], event.id, run_id)
    parent = self()

    # 并发写者：先锁 run 行；放行后提交 version+1（删除事务外的真实写者）
    writer =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT id FROM workflow_runs WHERE id = $1 FOR UPDATE", [
              Repo.uuid!(run_id)
            ])

            send(parent, :locked)

            receive do
              :release -> :ok
            end

            Repo.query!("UPDATE workflow_runs SET version = version + 1 WHERE id = $1", [
              Repo.uuid!(run_id)
            ])
          end)
        end)
      end)

    assert_receive :locked, 5_000

    delete_task = Task.async(fn -> unboxed(fn -> delete(event, owner) end) end)

    # 删除事务停在收口 UPDATE 上（阻塞在写者持有的 run 行锁）
    assert Task.yield(delete_task, 300) == nil

    send(writer.pid, :release)
    assert {:ok, _} = Task.await(writer, 5_000)

    # 写者已提交 version+1 → 收口的乐观锁 UPDATE 命中 0 行 → StaleRecord → 回滚
    # （嵌套事务场景 Ash 顶层错误透出原始 StaleRecord 文案而非域函数 fallback）
    assert {:error, error} = Task.await(delete_task, 5_000)
    assert Exception.message(error) =~ "stale record"

    unboxed(fn ->
      assert {:ok, %Event{status: :draft}} = Ash.get(Event, event.id, authorize?: false)

      invitations =
        SpeakerInvitation
        |> Ash.Query.filter(event_id == ^event.id)
        |> Ash.read!(authorize?: false, tenant: workspace.id)

      assert length(invitations) == 1

      run = Ash.get!(WorkflowRun, run_id, authorize?: false)
      assert run.status == :waiting
      assert is_nil(run.finished_at)
    end)
  end
end
