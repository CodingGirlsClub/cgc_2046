defmodule Cgc2046.Flashback.FutureEventsTest do
  @moduledoc """
  未来场次帧投影（U5/KTD1）：分组、时间过滤、公开口径、城市筛选。
  """

  use Cgc2046.DataCase, async: false

  alias Cgc2046.Flashback.AlumniProjection

  defp seed_future_event(title, slug, starts_at, city, initiative \\ nil) do
    # initiatives/events 是多租户表——走 SQL 直插（无租户面，public 投影同款字段）
    {initiative_slug, initiative_name} = initiative || {"hackerstart1024", "Hacker Start 1024"}

    init_id =
      case Cgc2046.Repo.query!("SELECT id FROM initiatives WHERE slug = $1", [initiative_slug]) do
        %{rows: [[id]]} ->
          id

        _ ->
          %{rows: [[id]]} =
            Cgc2046.Repo.query!(
              "INSERT INTO initiatives (id, slug, name, status, inserted_at, updated_at)
               VALUES (gen_random_uuid(), $1, $2, 'open', now(), now()) RETURNING id",
              [initiative_slug, initiative_name]
            )

          id
      end

    {venue_country, venue_province, venue_district} = {"中国", "-", "-"}

    ws_id =
      case Cgc2046.Repo.query!("SELECT id FROM workspaces LIMIT 1") do
        %{rows: [[id]]} ->
          id

        _ ->
          %{rows: [[id]]} =
            Cgc2046.Repo.query!(
              "INSERT INTO workspaces (id, name, slug, inserted_at, updated_at)
               VALUES (gen_random_uuid(), 'FutureEventsTest', 'future-events-test', now(), now()) RETURNING id"
            )

          id
      end

    Cgc2046.Repo.query!(
      """
      INSERT INTO events (id, slug, title, status, visibility, starts_at, venue, initiative_id, workspace_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $2, 'open', 'public', $3,
              jsonb_build_object('country', $4::text, 'province', $5::text, 'city', $6::text, 'district', $7::text),
              $8, $9, now(), now())
      """,
      [
        slug,
        title,
        starts_at,
        venue_country,
        venue_province,
        city || "",
        venue_district,
        init_id,
        ws_id
      ]
    )

    :ok
  end

  test "未来公开 open 场次按 initiative 分组、帧按最早场次排序" do
    seed_future_event("Agent 入门 A", "hs-a", ~U[2026-11-24 06:00:00Z], "北京")
    seed_future_event("Agent 入门 B", "hs-b", ~U[2026-10-24 06:00:00Z], "北京")
    seed_future_event("月度格场", "monthly-1", ~U[2026-12-01 08:00:00Z], "成都", {"monthly", "月度格"})

    frames = AlumniProjection.list_future_events()
    assert length(frames) == 2
    assert [%{initiative_slug: "hackerstart1024"} = hs, %{initiative_slug: "monthly"}] = frames
    assert hs.initiative_name == "Hacker Start 1024"
    assert Enum.map(hs.events, & &1.slug) == ["hs-b", "hs-a"]
  end

  test "已开始/非 open/非公开场次不出现（R2/R4）" do
    seed_future_event("未来场", "fut-1", ~U[2026-12-24 06:00:00Z], "北京")
    seed_future_event("已开始", "past-1", ~U[2026-09-19 00:00:00Z], "北京")

    Cgc2046.Repo.query!("UPDATE events SET status = 'closed' WHERE slug = 'fut-1'")

    frames = AlumniProjection.list_future_events()
    refute Enum.any?(frames, &Enum.any?(&1.events, fn e -> e.slug in ["past-1", "fut-1"] end))
  end

  test "城市筛选按 venue->>'city'（R15）" do
    seed_future_event("北京场", "bj-1", ~U[2026-12-24 06:00:00Z], "北京")
    seed_future_event("上海场", "sh-1", ~U[2026-12-25 06:00:00Z], "上海")

    frames = AlumniProjection.list_future_events("上海")
    assert [%{events: [%{slug: "sh-1"}]}] = frames
  end
end
