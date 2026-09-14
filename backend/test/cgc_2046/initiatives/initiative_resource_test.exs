defmodule Cgc2046.Initiatives.InitiativeResourceTest do
  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Event
  alias Cgc2046.EventsFixtures
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule}

  defp open_initiative(admin) do
    initiative =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "Hackerstart",
        slug: "hackerstart-test",
        created_by: admin.id
      })
      |> Ash.create!(actor: admin)

    rules = [
      {:deposit, %{enabled: true, amount_cents: 6_900}, true},
      {:age_gate, %{min_age: 18}, true},
      {:min_participants, %{count: 8}, false},
      {:deadline_rule, %{hours_before_start: 72}, false}
    ]

    Enum.each(rules, fn {key, value, locked} ->
      InitiativeRule
      |> Ash.Changeset.for_create(:create, %{
        initiative_id: initiative.id,
        key: key,
        value: value,
        locked: locked
      })
      |> Ash.create!(actor: admin)
    end)

    initiative
    |> Ash.Changeset.for_update(:open, %{})
    |> Ash.update!(actor: admin)
  end

  test "平台管理员创建 Initiative 与四项规则，规则完整后才能 open" do
    admin = Fixtures.platform_admin("initiative-resource")

    initiative =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "Incomplete",
        slug: "incomplete-test",
        created_by: admin.id
      })
      |> Ash.create!(actor: admin)

    assert_raise Ash.Error.Invalid, ~r/all four rules/, fn ->
      initiative
      |> Ash.Changeset.for_update(:open, %{})
      |> Ash.update!(actor: admin)
    end

    opened = open_initiative(admin)
    assert opened.status == :open
    assert length(Ash.read!(InitiativeRule, actor: admin)) == 4
  end

  test "草稿 Event 挂载后继承规则，锁死项不能被本地更新" do
    admin = Fixtures.platform_admin("initiative-mount")
    workspace = Fixtures.create_workspace(admin)
    initiative = open_initiative(admin)

    starts_at = DateTime.add(DateTime.utc_now(), 10, :day)

    event =
      Event
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "挂载活动",
          initiative_id: initiative.id,
          starts_at: starts_at,
          ends_at: DateTime.add(starts_at, 1, :day)
        },
        tenant: workspace.id
      )
      |> Ash.create!(actor: admin, tenant: workspace.id)

    assert event.initiative_id == initiative.id
    assert event.deposit_enabled == true
    assert event.min_age == 18
    assert event.min_participants == 8

    assert event.registration_deadline ==
             starts_at |> DateTime.add(-72 * 3600, :second) |> DateTime.truncate(:second)

    assert {:error, _} =
             event
             |> Ash.Changeset.for_update(:update, %{deposit_enabled: false}, tenant: workspace.id)
             |> Ash.update(actor: admin, tenant: workspace.id)

    updated =
      event
      |> Ash.Changeset.for_update(:update, %{min_participants: 4}, tenant: workspace.id)
      |> Ash.update!(actor: admin, tenant: workspace.id)

    assert updated.deposit_enabled == true
    assert updated.min_participants == 4
  end

  test "未挂载 Event 保持既有行为" do
    admin = Fixtures.platform_admin("initiative-legacy")
    workspace = Fixtures.create_workspace(admin)
    event = EventsFixtures.create_event(workspace, admin)

    assert is_nil(event.initiative_id)
    assert event.deposit_enabled == false
    assert is_nil(event.min_age)
    assert is_nil(event.min_participants)
    assert event.qualification_status == :pending
  end

  test "locked rule change propagates to mounted events while default change preserves local override" do
    admin = Fixtures.platform_admin("initiative-propagation")
    workspace = Fixtures.create_workspace(admin)
    initiative = open_initiative(admin)

    event =
      Event
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "传播活动",
          initiative_id: initiative.id,
          starts_at: DateTime.add(DateTime.utc_now(), 10, :day),
          ends_at: DateTime.add(DateTime.utc_now(), 11, :day)
        },
        tenant: workspace.id
      )
      |> Ash.create!(actor: admin, tenant: workspace.id)

    [deposit_rule] =
      InitiativeRule
      |> Ash.Query.filter(initiative_id == ^initiative.id and key == :deposit)
      |> Ash.read!(actor: admin)

    assert {:ok, _} =
             deposit_rule
             |> Ash.Changeset.for_update(:update, %{value: %{enabled: true, amount_cents: 5_900}})
             |> Ash.update(actor: admin)

    assert Ash.get!(Event, event.id, authorize?: false).deposit_amount_cents == 5_900

    assert {:ok, _} =
             deposit_rule
             |> Ash.Changeset.for_update(:update, %{
               value: %{enabled: true, amount_cents: 4_900},
               locked: false
             })
             |> Ash.update(actor: admin)

    assert Ash.get!(Event, event.id, authorize?: false).deposit_amount_cents == 5_900

    [min_rule] =
      InitiativeRule
      |> Ash.Query.filter(initiative_id == ^initiative.id and key == :min_participants)
      |> Ash.read!(actor: admin)

    event =
      event
      |> Ash.Changeset.for_update(:update, %{min_participants: 6}, tenant: workspace.id)
      |> Ash.update!(actor: admin, tenant: workspace.id)

    assert {:ok, _} =
             min_rule
             |> Ash.Changeset.for_update(:update, %{value: %{count: 10}})
             |> Ash.update(actor: admin)

    assert Ash.get!(Event, event.id, authorize?: false).min_participants == 6
  end

  test "mounted event remains editable after initiative closes" do
    admin = Fixtures.platform_admin("initiative-closed-edit")
    workspace = Fixtures.create_workspace(admin)
    initiative = open_initiative(admin)

    event =
      Event
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "可编辑活动",
          initiative_id: initiative.id,
          starts_at: DateTime.add(DateTime.utc_now(), 10, :day),
          ends_at: DateTime.add(DateTime.utc_now(), 11, :day)
        },
        tenant: workspace.id
      )
      |> Ash.create!(actor: admin, tenant: workspace.id)

    initiative
    |> Ash.Changeset.for_update(:close, %{})
    |> Ash.update!(actor: admin)

    assert {:ok, updated} =
             event
             |> Ash.Changeset.for_update(:update, %{title: "已更新"}, tenant: workspace.id)
             |> Ash.update(actor: admin, tenant: workspace.id)

    assert updated.title == "已更新"
  end
end
