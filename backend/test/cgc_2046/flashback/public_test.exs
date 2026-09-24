defmodule Cgc2046.Flashback.PublicTest do
  @moduledoc """
  U4 圆梦线 CTA 两态投影测试（R9）：`dream_target/1` 只出指路字段，
  命中 = open Initiative 下本城最近一场 open+public 场次。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Event
  alias Cgc2046.Flashback.Public
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule}

  # :open 要求四条规则齐备（同 initiatives/public_test.exs 的 initiative/2）
  defp open_initiative(admin, slug) do
    initiative =
      Initiative
      |> Ash.Changeset.for_create(:create, %{name: "1024", slug: slug, created_by: admin.id})
      |> Ash.create!(actor: admin)

    for {key, value} <- [
          {:deposit, %{enabled: false}},
          {:age_gate, %{min_age: 18}},
          {:min_participants, %{count: 8}},
          {:deadline_rule, %{hours_before_start: 72}}
        ] do
      InitiativeRule
      |> Ash.Changeset.for_create(:create, %{initiative_id: initiative.id, key: key, value: value})
      |> Ash.create!(actor: admin)
    end

    initiative
    |> Ash.Changeset.for_update(:open, %{})
    |> Ash.update!(actor: admin)
  end

  defp launched_event(workspace, admin, initiative, attrs) do
    Event
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          title: "1024 场次",
          initiative_id: initiative.id,
          starts_at: DateTime.add(DateTime.utc_now(), 10, :day),
          ends_at: DateTime.add(DateTime.utc_now(), 11, :day),
          venue: %{"country" => "中国", "province" => "北京", "city" => "北京", "district" => "朝阳"}
        },
        attrs
      ),
      tenant: workspace.id
    )
    |> Ash.create!(actor: admin, tenant: workspace.id)
    |> Ash.Changeset.for_update(:launch, %{}, tenant: workspace.id)
    |> Ash.update!(actor: admin, tenant: workspace.id)
  end

  test "本城有已发布场次 → 命中最近一场；未命中城市与 nil 城市各有兜底" do
    admin = Fixtures.platform_admin("flashback-public")
    workspace = Fixtures.create_workspace(admin)
    initiative = open_initiative(admin, "flashback-dream-target")

    event =
      launched_event(workspace, admin, initiative, %{slug: "1024-bj-ride", title: "1024 北京骑行场"})

    target = Public.dream_target("北京")
    assert target.event_slug == event.slug
    assert target.event_title == "1024 北京骑行场"
    assert target.initiative_slug == initiative.slug
    # 指路白名单：无个人字段
    assert Map.keys(target) |> MapSet.new() ==
             MapSet.new([:event_slug, :event_title, :starts_at, :initiative_slug])

    # 别的城市无场次 → nil（前端落 Initiative 公开页）
    refute Public.dream_target("上海")
    # city 为 nil（档案无城市）→ 不限城市，返回最近场次
    assert %{} = Public.dream_target(nil)
  end

  test "workspace-only / 未发布 / 草稿场次不命中" do
    admin = Fixtures.platform_admin("flashback-public-2")
    workspace = Fixtures.create_workspace(admin)
    initiative = open_initiative(admin, "flashback-dream-target-2")

    launched_event(workspace, admin, initiative, %{slug: "1024-bj-hidden", visibility: :workspace})

    refute Public.dream_target("北京")

    # 草稿（未 launch）场次同样不可报名，不命中
    Event
    |> Ash.Changeset.for_create(
      :create,
      %{
        title: "草稿场次",
        slug: "1024-bj-draft",
        initiative_id: initiative.id,
        starts_at: DateTime.add(DateTime.utc_now(), 12, :day),
        ends_at: DateTime.add(DateTime.utc_now(), 13, :day),
        venue: %{"country" => "中国", "province" => "北京", "city" => "北京", "district" => "朝阳"}
      },
      tenant: workspace.id
    )
    |> Ash.create!(actor: admin, tenant: workspace.id)

    refute Public.dream_target("北京")
  end
end
