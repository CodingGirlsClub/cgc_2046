defmodule Cgc2046Web.GraphqlFlashbackPublicSmokeTest do
  @moduledoc """
  #844 测试 PR（PR 2 flashback 搬迁前的钉测）：公开面（无门控）3 个
  GraphQL 字段的冒烟测试——flashbackCities / flashbackDreamTarget /
  flashbackPublicStats。走真实 POST /api/graphql 入口，钉住当前行为。

  变异验证（随附记录）：
  - M3a：`WishPublic.cities/0` 改为返回 `[]` → cities 测试红；
  - M3b：`Public.dream_target/1` 改为恒返回 nil → dream_target 测试红；
  - M3c：`Public.stats/0` 的 returned_count 改为 +1 → public_stats 测试红。
  """

  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Event
  alias Cgc2046.Flashback
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule}

  @moduletag :capture_log

  # 各文件自带 fixture 是现有惯例，抽成共享模块不在 #844 范围。
  defp post_graphql(query, variables \\ %{}) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query, "variables" => variables})
    |> json_response(200)
  end

  defp create_archive(key) do
    Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: key,
      name: "Rails Girls Beijing",
      city: "北京",
      occurred_on: ~D[2014-01-11]
    })
    |> Ash.create!(authorize?: false)
  end

  # :open 要求四条规则齐备（同 flashback/public_test.exs 的 open_initiative/2）
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

  defp launched_event(workspace, admin, initiative, slug) do
    Event
    |> Ash.Changeset.for_create(
      :create,
      %{
        title: "1024 北京骑行场",
        slug: slug,
        initiative_id: initiative.id,
        starts_at: DateTime.add(DateTime.utc_now(), 10, :day),
        ends_at: DateTime.add(DateTime.utc_now(), 11, :day),
        venue: %{"country" => "中国", "province" => "北京", "city" => "北京", "district" => "朝阳"}
      },
      tenant: workspace.id
    )
    |> Ash.create!(actor: admin, tenant: workspace.id)
    |> Ash.Changeset.for_update(:launch, %{}, tenant: workspace.id)
    |> Ash.update!(actor: admin, tenant: workspace.id)
  end

  @cities_query """
  query { flashbackCities { name fullName pinyin lngLat } }
  """

  test "flashbackCities：静态全国名单非空，首项四字段齐" do
    res = post_graphql(@cities_query)
    assert res["errors"] == nil

    cities = res["data"]["flashbackCities"]
    assert length(cities) >= 100

    assert [
             %{"name" => name, "fullName" => full_name, "pinyin" => pinyin, "lngLat" => lng_lat}
             | _
           ] =
             cities

    assert is_binary(name) and name != ""
    assert is_binary(full_name) and full_name != ""
    assert is_binary(pinyin) and pinyin != ""
    assert is_list(lng_lat) and length(lng_lat) == 2
  end

  @dream_target_query """
  query($city: String) {
    flashbackDreamTarget(city: $city) { eventSlug eventTitle initiativeSlug }
  }
  """

  test "flashbackDreamTarget：本城命中最近公开场次（eventSlug 指路），无场次城市为 null" do
    admin = Fixtures.platform_admin("fb-smoke-public")
    workspace = Fixtures.create_workspace(admin)
    initiative = open_initiative(admin, "fb-smoke-dream-#{System.unique_integer([:positive])}")

    event =
      launched_event(
        workspace,
        admin,
        initiative,
        "fb-smoke-bj-#{System.unique_integer([:positive])}"
      )

    res = post_graphql(@dream_target_query, %{"city" => "北京"})
    assert res["errors"] == nil

    assert %{
             "eventSlug" => event_slug,
             "eventTitle" => "1024 北京骑行场",
             "initiativeSlug" => initiative_slug
           } = res["data"]["flashbackDreamTarget"]

    assert event_slug == event.slug
    assert initiative_slug == initiative.slug

    # 无场次城市 → null（前端落 Initiative 公开页）
    res_miss = post_graphql(@dream_target_query, %{"city" => "上海"})
    assert res_miss["errors"] == nil
    assert res_miss["data"]["flashbackDreamTarget"] == nil
  end

  @stats_query """
  query { flashbackPublicStats { archives { key name city occurredOn appliedCount attendedCount } returnedCount sentCount } }
  """

  test "flashbackPublicStats：场次档案聚合可见，空 touch 计数为 0" do
    archive = create_archive("fb-smoke-stats-#{System.unique_integer([:positive])}")

    res = post_graphql(@stats_query)
    assert res["errors"] == nil

    stats = res["data"]["flashbackPublicStats"]
    assert stats["returnedCount"] == 0
    assert stats["sentCount"] == 0

    keys = Enum.map(stats["archives"], & &1["key"])
    assert archive.key in keys
  end
end
