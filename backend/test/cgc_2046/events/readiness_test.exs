defmodule Cgc2046.Events.ReadinessTest do
  @moduledoc """
  E-5 #50 G2：readiness 清单第三项 `sponsorship_tiers_configured` 正反例。

  - event `sponsorship_enabled=true` 且 tiers 空缺 → ok=false（warning 项）
  - event `sponsorship_enabled=true` 且 tiers 配好 → ok=true
  - event `sponsorship_enabled=false` → 恒 pass（不评估档位）
  - course 无赞助维度（无 sponsorship_enabled 字段）→ 恒 pass
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Readiness
  alias Cgc2046.EventsFixtures, as: EventFixtures

  defp sponsorship_item(entity) do
    entity
    |> Readiness.evaluate()
    |> Map.fetch!(:items)
    |> Enum.find(&(&1.key == "sponsorship_tiers_configured"))
  end

  describe "G2 sponsorship_tiers_configured" do
    test "event sponsorship_enabled=true 且 tiers 空缺 → ok=false（warning）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{sponsorship_enabled: true})

      assert event.sponsorship_tiers == []
      assert sponsorship_item(event).ok == false
    end

    test "event sponsorship_enabled=true 且 tiers 配好 → ok=true" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{
          sponsorship_enabled: true,
          sponsorship_tiers: [
            %{"id" => "t1", "name" => "Gold", "benefits" => [], "exclusive" => false}
          ]
        })

      assert sponsorship_item(event).ok == true
    end

    test "event sponsorship_enabled=false → 恒 pass（不评估档位）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{sponsorship_enabled: false})

      assert sponsorship_item(event).ok == true
    end

    test "course 无赞助维度 → 恒 pass" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin)

      assert sponsorship_item(course).ok == true
    end
  end

  describe "清单三项" do
    test "evaluate 返回三项（key 顺序稳定）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      %{items: items} = Readiness.evaluate(event)

      assert Enum.map(items, & &1.key) == [
               "registration_deadline",
               "research_definition",
               "sponsorship_tiers_configured"
             ]
    end
  end
end
