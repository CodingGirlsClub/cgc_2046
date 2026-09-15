defmodule Cgc2046.Events.EventModeratorsTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Events.{Event, EventModerator, Moderators}
  alias Cgc2046.EventsFixtures

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
end
