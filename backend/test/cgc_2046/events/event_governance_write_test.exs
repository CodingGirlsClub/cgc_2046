defmodule Cgc2046.Events.EventGovernanceWriteTest do
  @moduledoc """
  平台管理员治理写（U1/KTD1、KTD2）Event 侧：逐 action 放行 + 治理写逐笔留痕 +
  留痕失败 fail-closed 回滚 + 工作台 Owner 审计语义不变。

  放行面 = 只放 `:update`/`:launch`/`:close`/`:cancel`：create（自动指派创建者
  为主理人）与内部 update 型 action（`:qualify`/`:link_curriculum_run`）对平台
  管理员保持拒绝——策略放行按 action **名**逐条收口，不按 action_type 泛化。

  本文件 `async: false`：留痕故障注入走沙箱事务内 DDL（表级 ACCESS EXCLUSIVE
  锁，串行纪律同 `PaymentWorkersFailclosedGuardTest`）。
  """

  use Cgc2046.DataCase, async: false

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.Accounts.Changes.LogAdminAction
  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Event
  alias Cgc2046.EventsFixtures, as: EventFixtures

  require Ash.Query

  # 非成员平台管理员 + 普通用户 Owner 的工作台（平台管理员不在该台成员表里）
  defp tenant do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    %{owner: owner, workspace: workspace, admin: Fixtures.platform_admin()}
  end

  defp draft_event(workspace, actor, attrs \\ %{}) do
    Event
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{title: "治理写草稿", enrollment_policy: :open}, attrs),
      tenant: workspace.id
    )
    |> Ash.create!(tenant: workspace.id, actor: actor)
  end

  defp write(event, workspace, actor, action, attrs \\ %{}) do
    event
    |> Ash.Changeset.for_update(action, attrs, tenant: workspace.id, actor: actor)
    |> Ash.update(tenant: workspace.id, actor: actor)
  end

  defp reload(event), do: Ash.get!(Event, event.id, authorize?: false)

  defp logs_for(action, target_id) do
    AdminActionLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(action == ^action and target_id == ^target_id)
    |> Ash.read!(authorize?: false)
  end

  test "非成员平台管理员对 draft 场 launch：成功并留一行 admin_event_launch" do
    %{owner: owner, workspace: workspace, admin: admin} = tenant()
    event = draft_event(workspace, owner)
    refute MembershipContext.membership_of(admin, workspace.id)

    assert {:ok, launched} = write(event, workspace, admin, :launch)
    assert launched.status == :open
    assert reload(event).status == :open

    assert [log] = logs_for(:admin_event_launch, event.id)
    assert log.actor_id == admin.id
    assert log.target_type == :event
    assert log.result == :success
  end

  test "非成员平台管理员对 open 场 update/close/cancel：成功、逐笔留痕、自由文本不落 metadata" do
    %{owner: owner, workspace: workspace, admin: admin} = tenant()

    event =
      EventFixtures.create_event(workspace, owner, %{slug: "gov-update-event", capacity: 10})

    assert {:ok, updated} =
             write(event, workspace, admin, :update, %{
               title: "治理改名",
               capacity: 20,
               description: "自由文本 secret"
             })

    assert updated.title == "治理改名"

    assert [update_log] = logs_for(:admin_event_update, event.id)
    assert update_log.target_type == :event
    assert update_log.metadata["title_before"] == "Test Event"
    assert update_log.metadata["title_after"] == "治理改名"
    assert update_log.metadata["capacity_before"] == 10
    assert update_log.metadata["capacity_after"] == 20
    refute Map.has_key?(update_log.metadata, "description")
    refute inspect(update_log.metadata) =~ "自由文本 secret"

    assert {:ok, closed} = write(reload(event), workspace, admin, :close)
    assert closed.status == :closed
    assert [close_log] = logs_for(:admin_event_close, event.id)
    assert close_log.actor_id == admin.id

    cancelled_event = EventFixtures.create_event(workspace, owner)
    assert {:ok, cancelled} = write(cancelled_event, workspace, admin, :cancel)
    assert cancelled.status == :cancelled
    assert [cancel_log] = logs_for(:admin_event_cancel, cancelled_event.id)
    assert cancel_log.actor_id == admin.id
  end

  test "平台管理员对任意租户 createEvent 被拒（create 不放行）" do
    %{workspace: workspace, admin: admin} = tenant()

    assert {:error, %Ash.Error.Forbidden{}} =
             Event
             |> Ash.Changeset.for_create(
               :create,
               %{title: "治理建场", enrollment_policy: :open},
               tenant: workspace.id
             )
             |> Ash.create(tenant: workspace.id, actor: admin)
  end

  test "平台管理员直调内部 action（:qualify/:link_curriculum_run）被拒（R7 无旁路）" do
    %{owner: owner, workspace: workspace, admin: admin} = tenant()
    event = EventFixtures.create_event(workspace, owner)

    assert {:error, %Ash.Error.Forbidden{}} =
             write(event, workspace, admin, :qualify, %{qualification_status: :confirmed})

    assert {:error, %Ash.Error.Forbidden{}} =
             write(event, workspace, admin, :link_curriculum_run, %{
               workflow_run_id: Ecto.UUID.generate()
             })

    assert reload(event).qualification_status == :pending
  end

  test "平台管理员改已发布场 slug 被拒（code event_slug_locked）；draft 场仍可改" do
    %{owner: owner, workspace: workspace, admin: admin} = tenant()
    draft = draft_event(workspace, owner, %{slug: "gov-draft-slug"})

    assert {:ok, renamed} = write(draft, workspace, admin, :update, %{slug: "gov-draft-slug-2"})
    assert renamed.slug == "gov-draft-slug-2"

    published = EventFixtures.create_event(workspace, owner, %{slug: "gov-published-slug"})

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             write(published, workspace, admin, :update, %{slug: "gov-published-slug-2"})

    assert [%Cgc2046.Errors.BusinessError{code: "event_slug_locked", fields: [:slug]}] = errors
    assert reload(published).slug == "gov-published-slug"
  end

  test "工作台 Owner（非平台管理员）launch 成功且不落留痕（skip_unless 生效）" do
    %{owner: owner, workspace: workspace} = tenant()
    event = draft_event(workspace, owner)

    assert {:ok, launched} = write(event, workspace, owner, :launch)
    assert launched.status == :open
    assert logs_for(:admin_event_launch, event.id) == []
  end

  test "非成员普通用户写被拒（AE6 后端面）" do
    %{owner: owner, workspace: workspace} = tenant()
    outsider = Fixtures.register_user("gov-outsider")
    event = draft_event(workspace, owner)

    for action <- [:launch, :cancel, :close] do
      assert {:error, %Ash.Error.Forbidden{}} = write(event, workspace, outsider, action)
    end

    assert {:error, %Ash.Error.Forbidden{}} =
             write(event, workspace, outsider, :update, %{title: "越权改名"})

    assert reload(event).status == :draft
  end

  test "留痕 attrs 非法时：log!/3 上抛 vs log/3 返回（KTD2 raise 型原语分叉）" do
    %{owner: owner, workspace: workspace, admin: admin} = tenant()
    event = draft_event(workspace, owner)

    changeset =
      Ash.Changeset.for_update(event, :launch, %{}, tenant: workspace.id, actor: admin)

    bogus = %{action: :not_whitelisted_governance_action, target_type: :event}

    assert {:error, _} = LogAdminAction.log(changeset, event, bogus)

    assert_raise Ash.Error.Invalid, fn ->
      LogAdminAction.log!(changeset, event, bogus)
    end
  end

  test "留痕写入失败：治理写整体回滚（fail-closed，无半态）" do
    %{owner: owner, workspace: workspace, admin: admin} = tenant()
    event = draft_event(workspace, owner)

    # 注入：本场的 admin_event_launch 留痕 INSERT 必然失败（沙箱事务内 DDL，
    # 测试结束自动回滚）
    Cgc2046.Repo.query!("""
    CREATE OR REPLACE FUNCTION cgc_test_block_governance_log() RETURNS trigger AS
    $$ BEGIN RAISE EXCEPTION 'test injected log write failure'; END; $$ LANGUAGE plpgsql;
    """)

    Cgc2046.Repo.query!("""
    CREATE TRIGGER block_governance_log BEFORE INSERT ON admin_action_logs
    FOR EACH ROW WHEN (NEW.action = 'admin_event_launch')
    EXECUTE FUNCTION cgc_test_block_governance_log();
    """)

    outcome =
      try do
        write(event, workspace, admin, :launch)
      rescue
        exception -> {:raised, exception}
      end

    # 留痕失败即上抛（Ash 的 action 边界把异常折算成 {:error, %Ash.Error.Unknown{}}）：
    # 判据是**事务回滚**（返回型 log/3 在 after_action 语义下会提交事务 → 状态变
    # open，本断言即红），失败不落半态
    assert {:error, _} = outcome, "留痕写入失败必须让治理写失败，实际: #{inspect(outcome)}"
    assert reload(event).status == :draft
    assert logs_for(:admin_event_launch, event.id) == []

    # 解除注入 → 重入收敛：状态迁移与留痕一起落地
    Cgc2046.Repo.query!("DROP TRIGGER block_governance_log ON admin_action_logs")

    assert {:ok, launched} = write(reload(event), workspace, admin, :launch)
    assert launched.status == :open
    assert [_] = logs_for(:admin_event_launch, event.id)
  end
end
