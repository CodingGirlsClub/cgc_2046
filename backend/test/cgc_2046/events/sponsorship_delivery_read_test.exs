defmodule Cgc2046.Events.SponsorshipDeliveryReadTest do
  use Cgc2046.DataCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Sponsorship
  alias Cgc2046.EventsFixtures, as: EventFixtures

  @tier %{
    "id" => "9c4a1d30-0000-4000-8000-0000000000cc",
    "name" => "标准",
    "amount_suggestion" => 2_000,
    "benefits" => ["报名页露出"],
    "exclusive" => false
  }

  test "owner 经关系加载读取 deliveries；outsider 被拒" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin, %{sponsorship_tiers: [@tier]})
    owner = Fixtures.register_user("delivery-owner")
    Fixtures.add_member(workspace, owner, [:owner])
    outsider = Fixtures.register_user("delivery-outsider")
    event = EventFixtures.create_event(workspace, admin, %{sponsorship_tiers: [@tier]})
    sponsor = Fixtures.register_user("delivery-sponsor")

    {:ok, pending} =
      Sponsorship
      |> Ash.Changeset.for_create(:create_sponsorship, %{
        level: :event,
        event_id: event.id,
        sponsor_user_id: sponsor.id,
        tier_id: @tier["id"],
        company_name: "Acme",
        contact_email: sponsor.email
      })
      |> Ash.create(actor: sponsor)

    {:ok, _} =
      pending
      |> Ash.Changeset.for_update(:approve_sponsorship, %{})
      |> Ash.update(tenant: workspace.id, actor: admin)

    loaded = Ash.load!(pending, :deliveries, tenant: workspace.id, actor: owner)
    assert length(loaded.deliveries) == 1

    assert {:error, _} =
             Ash.load(pending, :deliveries, tenant: workspace.id, actor: outsider)

    # sponsor 本人经关系加载也可读（同 Sponsorship read policy 第一分支）
    loaded_sponsor = Ash.load!(pending, :deliveries, tenant: workspace.id, actor: sponsor)
    assert length(loaded_sponsor.deliveries) == 1
  end
end
