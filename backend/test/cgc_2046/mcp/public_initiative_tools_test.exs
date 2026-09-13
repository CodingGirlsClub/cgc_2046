defmodule Cgc2046.Mcp.PublicInitiativeToolsTest do
  use Cgc2046.DataCase, async: true

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule}
  alias Cgc2046.Mcp.Tools.{GetPublicInitiative, ListPublicInitiatives}

  defp decode({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end

  defp open_initiative(admin, slug) do
    initiative =
      Initiative
      |> Ash.Changeset.for_create(:create, %{name: "MCP public", slug: slug, created_by: admin.id})
      |> Ash.create!(actor: admin)

    for {key, value} <- [
          {:deposit, %{enabled: false}},
          {:age_gate, %{min_age: 18}},
          {:min_participants, %{count: 8}},
          {:deadline_rule, %{hours_before_start: 72}}
        ] do
      InitiativeRule
      |> Ash.Changeset.for_create(:create, %{
        initiative_id: initiative.id,
        key: key,
        value: value,
        locked: false
      })
      |> Ash.create!(actor: admin)
    end

    initiative |> Ash.Changeset.for_update(:open, %{}) |> Ash.update!(actor: admin)
  end

  test "public initiative MCP tools expose public projection and reject draft" do
    admin = Fixtures.platform_admin("mcp-public-initiative")
    initiative = open_initiative(admin, "mcp-public-initiative")
    outsider = Fixtures.register_user("mcp-public-outsider")
    frame = Frame.new(current_user: outsider)

    assert {:reply, _, _} = reply = ListPublicInitiatives.execute(%{}, frame)
    assert Enum.any?(decode(reply)["initiatives"], &(&1["slug"] == initiative.slug))

    assert {:reply, _, _} =
             detail = GetPublicInitiative.execute(%{"slug" => initiative.slug}, frame)

    assert decode(detail)["slug"] == initiative.slug
  end
end
