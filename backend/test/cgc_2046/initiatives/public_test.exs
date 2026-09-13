defmodule Cgc2046.Initiatives.PublicTest do
  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Event
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule, Public}

  defp initiative(admin, slug) do
    initiative =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "Public Initiative",
        slug: slug,
        created_by: admin.id
      })
      |> Ash.create!(actor: admin)

    for {key, value, locked} <- [
          {:deposit, %{enabled: true, amount_cents: 6_900}, true},
          {:age_gate, %{min_age: 18}, true},
          {:min_participants, %{count: 8}, false},
          {:deadline_rule, %{hours_before_start: 72}, false}
        ] do
      InitiativeRule
      |> Ash.Changeset.for_create(:create, %{
        initiative_id: initiative.id,
        key: key,
        value: value,
        locked: locked
      })
      |> Ash.create!(actor: admin)
    end

    initiative
    |> Ash.Changeset.for_update(:open, %{})
    |> Ash.update!(actor: admin)
  end

  defp event(workspace, admin, initiative, attrs) do
    Event
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{title: "公开场次", initiative_id: initiative.id}, attrs),
      tenant: workspace.id
    )
    |> Ash.create!(actor: admin, tenant: workspace.id)
    |> then(fn event ->
      event
      |> Ash.Changeset.for_update(:launch, %{}, tenant: workspace.id)
      |> Ash.update!(actor: admin, tenant: workspace.id)
    end)
  end

  test "公开投影跨工作台按城市分组并排除 workspace-only" do
    admin = Fixtures.platform_admin("initiative-public")
    workspace = Fixtures.create_workspace(admin)
    initiative = initiative(admin, "public-initiative-test")

    event(workspace, admin, initiative, %{
      venue: %{"city" => "长沙", "province" => "湖南", "country" => "中国", "district" => "岳麓"}
    })

    event(workspace, admin, initiative, %{venue: nil})

    hidden =
      Event
      |> Ash.Changeset.for_create(
        :create,
        %{title: "隐藏场次", initiative_id: initiative.id, visibility: :workspace},
        tenant: workspace.id
      )
      |> Ash.create!(actor: admin, tenant: workspace.id)
      |> Ash.Changeset.for_update(:launch, %{}, tenant: workspace.id)
      |> Ash.update!(actor: admin, tenant: workspace.id)

    assert hidden.visibility == :workspace
    assert {:ok, payload} = Public.get_by_slug("public-initiative-test")
    assert payload.event_count == 2
    assert payload.city_count == 2
    assert Enum.map(payload.cities, & &1.city) == ["线上 / 待定", "长沙"]
    assert payload.confirmed_count == 0
  end

  test "draft 或不存在的 Initiative 不可公开读取" do
    admin = Fixtures.platform_admin("initiative-public-draft")

    draft =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "Draft",
        slug: "draft-initiative-test",
        created_by: admin.id
      })
      |> Ash.create!(actor: admin)

    assert {:error, :not_found} = Public.get_by_slug(draft.slug)
    assert {:error, :not_found} = Public.get_by_slug("missing-initiative")
  end
end
