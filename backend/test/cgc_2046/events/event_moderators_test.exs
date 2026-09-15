defmodule Cgc2046.Events.EventModeratorsTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.{Event, EventModerator, Moderators}
  alias Cgc2046.EventsFixtures

  test "creator is assigned by event create and non-member moderator can be assigned" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    user = Fixtures.register_user("moderator")
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
end
