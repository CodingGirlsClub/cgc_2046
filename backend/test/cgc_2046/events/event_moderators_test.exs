defmodule Cgc2046.Events.EventModeratorsTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Events.{Event, EventModerator, Moderators}
  alias Cgc2046.EventsFixtures

  require Ash.Query

  test "creator is assigned by event create; member assign/remove round-trip" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    user = Fixtures.register_user("moderator")
    Fixtures.add_member(workspace, user, [:learner])
    event = EventsFixtures.create_event(workspace, owner)

    # The fixture uses the authenticated creator; creator assignment is observable
    # through the real EventModerator resource.
    assert {:ok, moderators} = Moderators.list(event.id, workspace.id, owner)
    assert Enum.any?(moderators, &(&1.user_id == owner.id))

    assert {:ok, assigned} = Moderators.assign(event.id, workspace.id, user.id, owner)
    assert assigned.user_id == user.id
    assert Moderators.moderator?(user.id, event.id, workspace.id)

    assert {:error, :forbidden} = Moderators.assign(event.id, workspace.id, owner.id, user)

    # 撤权走域唯一入口（GraphQL/MCP 共用 Moderators.remove，U7 AE8）
    assert :ok = Moderators.remove(assigned.id, workspace.id, owner)

    refute Moderators.moderator?(user.id, event.id, workspace.id)
    assert Ash.get!(Event, event.id, authorize?: false).status == :open

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.get(EventModerator, assigned.id, authorize?: false)

    # 已移除的记录再走域入口 → not_found（幂等边界）
    assert {:error, :not_found} = Moderators.remove(assigned.id, workspace.id, owner)

    # 非管理角色不可撤权
    assert {:error, :forbidden} =
             Moderators.assign(event.id, workspace.id, user.id, owner)
             |> then(fn {:ok, record} -> Moderators.remove(record.id, workspace.id, user) end)
  end

  test "非成员指派被拒（#558 成员前提）：稳定 code 引导先邀请入台；入台后放行" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    # register_user 自动加入默认 2046 工作台，但不是本 workspace 的成员
    outsider = Fixtures.register_user("outsider")
    event = EventsFixtures.create_event(workspace, owner)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Moderators.assign(event.id, workspace.id, outsider.id, owner)

    assert Enum.any?(
             errors,
             &match?(%BusinessError{code: "event_moderator_not_workspace_member"}, &1)
           ),
           "expected event_moderator_not_workspace_member, got: #{inspect(errors)}"

    refute Moderators.moderator?(outsider.id, event.id, workspace.id)

    # 入台（任意角色，learner 即可）后同一指派放行
    Fixtures.add_member(workspace, outsider, [:learner])
    assert {:ok, assigned} = Moderators.assign(event.id, workspace.id, outsider.id, owner)
    assert Moderators.moderator?(outsider.id, event.id, workspace.id)
    assert :ok = Moderators.remove(assigned.id, workspace.id, owner)
  end

  test "成员离台级联撤销其主理人指派（#561）：本台清空、他台不动、审计落行" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    other_workspace = Fixtures.create_workspace(owner)
    user = Fixtures.register_user("cascade-mod")
    Fixtures.add_member(workspace, user, [:learner])
    Fixtures.add_member(other_workspace, user, [:learner])
    event = EventsFixtures.create_event(workspace, owner)
    other_event = EventsFixtures.create_event(other_workspace, owner)

    {:ok, _} = Moderators.assign(event.id, workspace.id, user.id, owner)
    {:ok, _} = Moderators.assign(other_event.id, other_workspace.id, user.id, owner)

    # 指派审计落行（#561 接活沉睡原子）：target = 活动，metadata 带被指派者
    assert [_, _] = moderator_logs(:event_moderator_assign, event.id)
    assert [_, _] = moderator_logs(:event_moderator_assign, other_event.id)

    # 离台（destroy 本台 membership，唯一写边界）
    membership = Cgc2046.Accounts.MembershipContext.membership_of(user, workspace.id)
    Ash.destroy!(membership, actor: owner, tenant: workspace.id)

    # 本台指派清空 + 级联审计（cascade 标记与主动撤销区分）；他台不动
    refute Moderators.moderator?(user.id, event.id, workspace.id)
    assert Moderators.moderator?(user.id, other_event.id, other_workspace.id)

    assert [cascade_log] = moderator_logs(:event_moderator_remove, event.id)
    assert cascade_log.metadata["cascade"] == "membership_destroy"
    assert cascade_log.metadata["user_id"] == user.id
    assert moderator_logs(:event_moderator_remove, other_event.id) == []
  end

  test "主动撤销主理人落审计（无 cascade 标记，与离台级联区分）" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    user = Fixtures.register_user("manual-remove-mod")
    Fixtures.add_member(workspace, user, [:learner])
    event = EventsFixtures.create_event(workspace, owner)

    {:ok, assigned} = Moderators.assign(event.id, workspace.id, user.id, owner)
    assert :ok = Moderators.remove(assigned.id, workspace.id, owner)

    assert [log] = moderator_logs(:event_moderator_remove, event.id)
    assert log.metadata["user_id"] == user.id
    refute log.metadata["cascade"]
  end

  # ── #611：重复指派撞 identity 唯一索引 → 稳定 code（不再落 database_error） ──
  test "重复指派：event_moderator_already_assigned + 无库内文本 + 不落第二行" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    user = Fixtures.register_user("dup-mod")
    Fixtures.add_member(workspace, user, [:learner])
    event = EventsFixtures.create_event(workspace, owner)

    {:ok, _} = Moderators.assign(event.id, workspace.id, user.id, owner)

    assert {:error, %Ash.Error.Invalid{errors: errors} = error} =
             Moderators.assign(event.id, workspace.id, user.id, owner)

    assert Enum.any?(
             errors,
             &match?(
               %BusinessError{code: "event_moderator_already_assigned", fields: [:user_id]},
               &1
             )
           ),
           "expected event_moderator_already_assigned, got: #{inspect(errors)}"

    message = Exception.message(error)
    assert message =~ "this user is already a moderator of the event"
    refute message =~ "event_moderators_event_id_user_id_index"
    refute message =~ "event_moderators_unique_event_user_index"
    refute message =~ "duplicate key"
    refute message =~ "constraint error"

    assert [row] =
             EventModerator
             |> Ash.Query.filter(event_id == ^event.id and user_id == ^user.id)
             |> Ash.read!(authorize?: false)

    assert row.user_id == user.id
  end

  # ensure_assigned/2 的幂等语义必须由**稳定 code** 承载，不得再依赖
  # Ecto.ConstraintError 原文（改名对齐索引后原文里的注册约束名消失）。
  test "ensure_assigned 幂等：重复调用仍 :ok（判据 = event_moderator_already_assigned）" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    event = EventsFixtures.create_event(workspace, owner)

    assert :ok = Moderators.ensure_assigned(event, owner.id)
    assert :ok = Moderators.ensure_assigned(event, owner.id)
  end

  # 审计行断言收窄到本测试独占的 target_id（共享沙箱不见他测试未提交行，
  # 但本测试的多次写同 target 会累积——按 target 过滤即可）
  defp moderator_logs(action, event_id) do
    Cgc2046.Accounts.AdminActionLog
    |> Ash.Query.filter(action == ^action and target_id == ^event_id)
    |> Ash.read!(authorize?: false)
  end
end
