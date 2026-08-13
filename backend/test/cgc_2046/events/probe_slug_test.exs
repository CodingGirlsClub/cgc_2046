defmodule Cgc2046.Events.ProbeSlugTest do
  use Cgc2046.DataCase, async: false
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Event

  test "probe force_change" do
    admin = Fixtures.platform_admin()
    ws = Fixtures.create_workspace(admin)

    cs =
      Event |> Ash.Changeset.for_create(:create, %{title: "probe"}, tenant: ws.id, actor: admin)

    cs2 = Ash.Changeset.force_change_attribute(cs, :description, "hello")
    IO.inspect(Ash.Changeset.get_attribute(cs2, :description), label: "after force_change")
    IO.inspect(Map.get(cs2.attributes, :description), label: "raw map after")
    IO.inspect(cs2.valid?(), label: "valid")
  end
end
