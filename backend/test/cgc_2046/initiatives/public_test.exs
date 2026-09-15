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
      Map.merge(
        %{
          title: "公开场次",
          initiative_id: initiative.id,
          # 押金规则锁死挂载（U3：押金开启要求非空 ends_at 锚点）
          starts_at: DateTime.add(DateTime.utc_now(), 10, :day),
          ends_at: DateTime.add(DateTime.utc_now(), 11, :day)
        },
        attrs
      ),
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
        %{
          title: "隐藏场次",
          initiative_id: initiative.id,
          visibility: :workspace,
          starts_at: DateTime.add(DateTime.utc_now(), 10, :day),
          ends_at: DateTime.add(DateTime.utc_now(), 11, :day)
        },
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

  test "公开列表 open 排在 closed 之前（R5）" do
    admin = Fixtures.platform_admin("initiative-public-list-order")

    closed =
      initiative(admin, "list-order-closed")
      |> Ash.Changeset.for_update(:update, %{window_starts_at: ~U[2026-12-01 00:00:00Z]})
      |> Ash.update!(actor: admin)

    open =
      initiative(admin, "list-order-open")
      |> Ash.Changeset.for_update(:update, %{window_starts_at: ~U[2026-10-01 00:00:00Z]})
      |> Ash.update!(actor: admin)

    closed
    |> Ash.Changeset.for_update(:close, %{})
    |> Ash.update!(actor: admin)

    # closed 的时间窗更晚，若按窗口排序 closed 会在前——open-first 必须先于窗口序
    assert DateTime.compare(closed.window_starts_at, open.window_starts_at) == :gt

    assert {:ok, rows} = Public.list()
    statuses = rows |> Enum.filter(&(&1.slug in [closed.slug, open.slug])) |> Enum.map(& &1.slug)
    assert statuses == [open.slug, closed.slug]
  end

  test "组内二级排序保持窗口倒序（code-review 缺口）" do
    admin = Fixtures.platform_admin("initiative-public-order-secondary")

    older = initiative(admin, "secondary-older")

    older
    |> Ash.Changeset.for_update(:update, %{window_starts_at: ~U[2026-10-01 00:00:00Z]})
    |> Ash.update!(actor: admin)

    newer = initiative(admin, "secondary-newer")

    newer
    |> Ash.Changeset.for_update(:update, %{window_starts_at: ~U[2026-12-01 00:00:00Z]})
    |> Ash.update!(actor: admin)

    assert {:ok, rows} = Public.list()

    slugs =
      rows
      |> Enum.filter(&(&1.slug in [older.slug, newer.slug]))
      |> Enum.map(& &1.slug)

    assert slugs == [older.slug, newer.slug]
  end

  test "公开投影查询数与场次数无关（U4 无 N+1 回归）" do
    admin = Fixtures.platform_admin("initiative-public-n1")
    workspace = Fixtures.create_workspace(admin)
    initiative = initiative(admin, "public-n1-test")

    venue = %{"city" => "长沙", "province" => "湖南", "country" => "中国", "district" => "岳麓"}

    for _ <- 1..2, do: event(workspace, admin, initiative, %{venue: venue})

    small = count_queries(fn -> Public.get_by_slug("public-n1-test") end)

    for _ <- 1..10, do: event(workspace, admin, initiative, %{venue: venue})

    large = count_queries(fn -> Public.get_by_slug("public-n1-test") end)

    assert small == large
    assert small <= 3
  end

  defp count_queries(fun) do
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      {__MODULE__, ref},
      [:cgc_2046, :repo, :query],
      fn _event, _measurements, _metadata, _config -> send(test_pid, {:query_counted, ref}) end,
      nil
    )

    fun.()
    count = drain_query_messages(ref, 0)
    :telemetry.detach({__MODULE__, ref})
    count
  end

  defp drain_query_messages(ref, acc) do
    receive do
      {:query_counted, ^ref} -> drain_query_messages(ref, acc + 1)
    after
      0 -> acc
    end
  end
end
