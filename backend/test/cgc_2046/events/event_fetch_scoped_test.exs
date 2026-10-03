defmodule Cgc2046.Events.EventFetchScopedTest do
  @moduledoc """
  `Event.fetch_scoped/3` 的租户收紧读取端口契约：
  跨工作台 Event ID 不泄露存在性，并保留 agent-facing 错误形状。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Event
  alias Cgc2046.EventsFixtures, as: EventFixtures

  test "owner reads an event in the same workspace" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    event = EventFixtures.create_event(workspace, owner)

    assert {:ok, %Event{id: id}} =
             Event.fetch_scoped(workspace.id, event.id, actor: owner)

    assert id == event.id
  end

  test "cross-workspace event id returns the exact not-found shape" do
    %{owner: owner_a, workspace: workspace_a} = Fixtures.workspace_with_member()
    %{owner: owner_b, workspace: workspace_b} = Fixtures.workspace_with_member()
    event_b = EventFixtures.create_event(workspace_b, owner_b)
    event_b_id = event_b.id

    assert {:error, "event not found: " <> ^event_b_id} =
             Event.fetch_scoped(workspace_a.id, event_b_id, actor: owner_a)

    assert {:error, "event not found: 00000000-0000-0000-0000-000000000000"} =
             Event.fetch_scoped(
               workspace_a.id,
               "00000000-0000-0000-0000-000000000000",
               actor: owner_a
             )

    assert {:ok, %Event{id: ^event_b_id}} =
             Event.fetch_scoped(workspace_b.id, event_b_id, actor: owner_b)
  end

  test "an invalid event id preserves the Ash invalid error" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()

    assert {:error, %Ash.Error.Invalid{}} =
             Event.fetch_scoped(workspace.id, "not-an-event-id", actor: owner)
  end
end
