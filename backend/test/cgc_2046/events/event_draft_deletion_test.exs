defmodule Cgc2046.Events.EventDraftDeletionTest do
  @moduledoc """
  #676 draft 活动删除（`Event :delete`，ADR-0015）：

  - draft 删除成功：行消失、**同 slug 立即可复用**、主理人行（event_moderators）
    随 FK `on_delete: delete_all` 级联消失
  - 非 draft（open）拒绝：`cannot delete from status=open`，行不动
  - 域权限收窄：admin ❌（Forbidden）；平台管理员 ✅（非成员亦放行）
  """
  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.{Event, EventModerator, Moderators}

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
end
