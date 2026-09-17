defmodule Cgc2046.Initiatives.PublicTest do
  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Event
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule, Public}
  alias Cgc2046.Offering

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

  # 押金 / 年龄规则 unlocked 的变体：挂载那一刻快照取值，之后场主仍可本地改写
  # ——覆盖「免费 / 收费 / 无年龄门槛」三态（锁死规则下这些态不可达）。
  defp unlocked_initiative(admin, slug) do
    initiative =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "Public Initiative",
        slug: slug,
        created_by: admin.id
      })
      |> Ash.create!(actor: admin)

    for {key, value, locked} <- [
          {:deposit, %{enabled: false}, false},
          {:age_gate, %{min_age: 18}, false},
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

  defp update_event(event, workspace, admin, attrs) do
    event
    |> Ash.Changeset.for_update(:update, attrs, tenant: workspace.id)
    |> Ash.update!(actor: admin, tenant: workspace.id)
  end

  defp all_events(payload), do: Enum.flat_map(payload.cities, & &1.events)

  # venue 校验要求 country/province/city/district 四键齐备（Events.Venue.valid?/1）
  defp venue(city) do
    %{"country" => "中国", "province" => "湖南", "city" => city, "district" => "岳麓"}
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

  # 脱敏边界（signoff 2026-09-14「公开 DTO 脱敏核对」）：公开投影不得出现 capacity 原值 /
  # workspace_id。payload 顶层与事件 DTO 两层都白名单化——新增公开字段必须显式过审，
  # 把文档承诺变成 CI 不变量（#593）。
  test "公开投影只暴露白名单字段（payload 顶层 + 事件 DTO，无 capacity / workspace_id）" do
    admin = Fixtures.platform_admin("initiative-public-dto-keys")
    workspace = Fixtures.create_workspace(admin)
    initiative = initiative(admin, "public-dto-keys-test")

    event(workspace, admin, initiative, %{
      venue: %{"city" => "长沙", "province" => "湖南", "country" => "中国", "district" => "岳麓"}
    })

    assert {:ok, payload} = Public.get_by_slug("public-dto-keys-test")

    payload_keys = Map.keys(payload)

    event_keys =
      payload.cities
      |> Enum.flat_map(& &1.events)
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()

    # 防空断言空转：两层都必须真的取到键（true-on-empty 不算绿）
    assert payload_keys != []
    assert event_keys != []

    allowed_payload = [
      :cities,
      :city_count,
      :confirmed_count,
      :description,
      :event_count,
      :hashtag,
      :id,
      :name,
      :qualified_event_count,
      :slug,
      :status,
      :url,
      :window_ends_at,
      :window_starts_at
    ]

    allowed_event = [
      :archived,
      :confirmed_count,
      :deposit,
      :ends_at,
      :id,
      :min_age,
      :min_participants,
      :payment_mode,
      :price_range_min_cents,
      :qualification_badge,
      :qualification_status,
      :registration_deadline,
      :short_by,
      :slug,
      :starts_at,
      :status,
      :title,
      :venue,
      :visibility
    ]

    # 子集断言：出现白名单外字段即 fail（新增公开字段必须显式过审；删字段不误报）
    assert payload_keys -- allowed_payload == [],
           "公开 payload 出现白名单外字段：#{inspect(payload_keys -- allowed_payload)}"

    assert event_keys -- allowed_event == [],
           "公开事件 DTO 出现白名单外字段：#{inspect(event_keys -- allowed_event)}"

    # 内部键两层都不得出现（子集断言已覆盖，这里显式钉住语义）
    refute :capacity in payload_keys
    refute :workspace_id in payload_keys
    refute :capacity in event_keys
    refute :workspace_id in event_keys
    # #627 参与条件披露是**新增白名单**，不是把规则表搬上公开面
    refute :rules in event_keys
    refute :locked in event_keys
    refute :value_json in event_keys
  end

  # #627 参与条件披露：押金（必须）/ 年龄门槛存在性 / 成班进度，全部取 Event 已物化
  # 快照列，读面不碰 `initiative_rules`。锁死规则挂载 → 值是规则效果，但公开面出的是
  # **事件快照**，不是规则 value map。
  test "公开投影披露押金三态 + 年龄门槛 + 金额锚（#627）" do
    admin = Fixtures.platform_admin("initiative-public-participation")
    workspace = Fixtures.create_workspace(admin)
    initiative = initiative(admin, "public-participation-deposit")

    event(workspace, admin, initiative, %{
      venue: %{"city" => "长沙", "province" => "湖南", "country" => "中国", "district" => "岳麓"}
    })

    assert {:ok, payload} = Public.get_by_slug("public-participation-deposit")
    assert [row] = all_events(payload)

    # 押金：金额 + 状态（交易前提，裁决「必须披露」）
    assert row.payment_mode == "deposit"
    assert row.deposit == %{enabled: true, amount_cents: 6_900, refundable_on_check_in: true}

    # 押金场档位恒空（DB CHECK events_deposit_excludes_price_tiers）→ 无收费金额锚
    assert row.price_range_min_cents == nil
    # 年龄：只出「门槛存在性」（整数），不出校验策略
    assert row.min_age == 18

    # 成班进度复用既有徽章派生，不新增进度字段（#593 裁决）
    assert row.min_participants == 8
    assert row.confirmed_count == 0
    assert row.short_by == 8
    assert row.qualification_badge == "short_by"
  end

  test "参与条件三态：免费 / 收费金额锚 / 无年龄门槛（#627）" do
    admin = Fixtures.platform_admin("initiative-public-participation-states")
    workspace = Fixtures.create_workspace(admin)
    initiative = unlocked_initiative(admin, "public-participation-states")

    free = event(workspace, admin, initiative, %{venue: venue("长沙")})
    priced = event(workspace, admin, initiative, %{venue: venue("北京")})
    stale = event(workspace, admin, initiative, %{venue: venue("上海")})

    # 免费 + 清掉年龄门槛（unlocked 规则允许场主本地改写）
    free = update_event(free, workspace, admin, %{min_age: nil})

    priced =
      update_event(priced, workspace, admin, %{
        pricing_enabled: true,
        price_tiers: [
          %{"id" => Ash.UUID.generate(), "name" => "早鸟票", "amount_cents" => 9_900},
          %{"id" => Ash.UUID.generate(), "name" => "标准票", "amount_cents" => 19_900}
        ]
      })

    # 收费开启但档位全部过期（available_until 过滤）→ 金额锚 nil，前端走降级文案
    stale =
      update_event(stale, workspace, admin, %{
        pricing_enabled: true,
        price_tiers: [
          %{
            "id" => Ash.UUID.generate(),
            "name" => "过期票",
            "amount_cents" => 9_900,
            "available_until" => "2020-01-01T00:00:00Z"
          }
        ]
      })

    assert {:ok, payload} = Public.get_by_slug("public-participation-states")

    rows = payload.cities |> Enum.flat_map(& &1.events) |> Map.new(&{&1.slug, &1})

    free_row = rows[free.slug]
    assert free_row.payment_mode == "free"
    assert free_row.deposit == %{enabled: false, amount_cents: nil, refundable_on_check_in: nil}
    assert free_row.min_age == nil
    assert free_row.price_range_min_cents == nil

    priced_row = rows[priced.slug]
    assert priced_row.payment_mode == "pricing"
    assert priced_row.deposit == %{enabled: false, amount_cents: nil, refundable_on_check_in: nil}
    # 只出**可售**档位最小值（原始档位数组不投公开面）
    assert priced_row.price_range_min_cents == 9_900
    assert priced_row.min_age == 18

    stale_row = rows[stale.slug]
    assert stale_row.payment_mode == "pricing"
    assert stale_row.price_range_min_cents == nil

    # F2：free 态即使残留档位（`update_event(pricing_enabled: false)` 不清 price_tiers，
    # 无 DB CHECK 拦这一侧）也不得给金额锚——客户端按 mode 门控看不见，MCP 看得到。
    residual = event(workspace, admin, initiative, %{venue: venue("广州")})

    residual =
      update_event(residual, workspace, admin, %{
        pricing_enabled: true,
        price_tiers: [
          %{"id" => Ash.UUID.generate(), "name" => "残留票", "amount_cents" => 9_900}
        ]
      })

    residual = update_event(residual, workspace, admin, %{pricing_enabled: false})
    assert residual.price_tiers != []

    assert {:ok, residual_payload} = Public.get_by_slug("public-participation-states")

    residual_row =
      residual_payload.cities
      |> Enum.flat_map(& &1.events)
      |> Enum.find(&(&1.slug == residual.slug))

    assert residual_row.payment_mode == "free"
    assert residual_row.price_range_min_cents == nil

    # 缴费槽形状与 MCP 读面（#586 唯一出口）逐字同源——两面漂移即红
    for {row, event} <- [{free_row, free}, {priced_row, priced}, {stale_row, stale}] do
      assert row.deposit == Offering.payment_slot(event).deposit
      assert row.payment_mode == Offering.payment_slot(event).payment_mode
    end
  end

  # F5：`events.min_age` 无 DB CHECK，force write / 裸 SQL 的存量脏行可带非正数；
  # 公开面只出正数门槛（渲染层「限 0+」比不出更糟）。
  test "年龄门槛只出正数：非正脏行降级为无门槛（#627 F5）" do
    admin = Fixtures.platform_admin("initiative-public-min-age-dirty")
    workspace = Fixtures.create_workspace(admin)
    initiative = unlocked_initiative(admin, "public-participation-min-age")

    event = event(workspace, admin, initiative, %{venue: venue("长沙")})
    assert event.min_age == 18

    # 布置而非被测对象：域 action 的 min: 1 约束挡住 0，只有裸 SQL 能造出存量脏行
    Repo.query!("UPDATE events SET min_age = 0 WHERE id = $1", [Ecto.UUID.dump!(event.id)])

    assert {:ok, payload} = Public.get_by_slug("public-participation-min-age")
    assert [row] = all_events(payload)
    assert row.min_age == nil
  end

  # 已取消 / 已结束留档场：参与条件披露不改变留档路径（徽章仍由后端派生），
  # 且新增字段在 cancelled/closed 上照常取值（不因归档丢字段）。
  test "已取消 / 已结束场的参与条件照常披露（#627 回归）" do
    admin = Fixtures.platform_admin("initiative-public-participation-archived")
    workspace = Fixtures.create_workspace(admin)
    initiative = initiative(admin, "public-participation-archived")

    cancelled =
      event(workspace, admin, initiative, %{venue: venue("长沙")})
      |> then(fn e ->
        e
        |> Ash.Changeset.for_update(:cancel, %{}, tenant: workspace.id)
        |> Ash.update!(actor: admin, tenant: workspace.id)
      end)

    assert {:ok, payload} = Public.get_by_slug("public-participation-archived")
    assert [row] = all_events(payload)

    assert row.status == "cancelled"
    assert row.qualification_badge == "cancelled"
    assert row.archived == true
    # 归档不丢参与条件
    assert row.payment_mode == "deposit"
    assert row.deposit.amount_cents == 6_900
    assert row.min_age == 18
    assert row.slug == cancelled.slug
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

  # 公开页绝对链接单源（MCP 工具与后续渠道投放共用；web 侧 canonical/sitemap
  # 由 web/lib/seo.ts 生成）。base 取 config :cgc_2046, :web_base_url。
  test "public_url/1 拼绝对公开页链接；nil 返回 nil" do
    base =
      Application.get_env(:cgc_2046, :web_base_url, "http://localhost:3000")
      |> to_string()
      |> String.trim_trailing("/")

    assert Public.public_url("hackerstart1024") == "#{base}/initiatives/hackerstart1024"
    assert Public.public_url(nil) == nil
    # 路径分隔符/查询串必须被编码进单段（slug 值注入不了路径）
    assert Public.public_url("a/b?c#d") == "#{base}/initiatives/a%2Fb%3Fc%23d"
  end

  test "公开投影带 url 字段（详情与列表同口径，且与 public_url/1 同值）" do
    admin = Fixtures.platform_admin("initiative-public-url")
    initiative = initiative(admin, "public-url-test")
    expected = Public.public_url(initiative.slug)

    assert {:ok, payload} = Public.get_by_slug(initiative.slug)
    assert payload.url == expected

    assert {:ok, rows} = Public.list()
    row = Enum.find(rows, &(&1.slug == initiative.slug))
    assert row.url == expected
  end

  # #596 权限不扩大：规则（值/锁态）不得进入匿名公开投影。键集冻结 —— 新增字段
  # 会红，迫使人重新裁决「公开面能否看见」。
  test "公开投影键集冻结：详情/列表 DTO 不含规则（#596）" do
    admin = Fixtures.platform_admin("initiative-public-dto")
    workspace = Fixtures.create_workspace(admin)
    initiative = initiative(admin, "public-dto-test")
    event(workspace, admin, initiative, %{})

    assert {:ok, payload} = Public.get_by_slug("public-dto-test")

    assert Enum.sort(Map.keys(payload)) ==
             Enum.sort([
               :id,
               :name,
               :slug,
               :url,
               :hashtag,
               :description,
               :window_starts_at,
               :window_ends_at,
               :status,
               :city_count,
               :event_count,
               :confirmed_count,
               :qualified_event_count,
               :cities
             ])

    assert {:ok, rows} = Public.list()
    row = Enum.find(rows, &(&1.slug == initiative.slug))

    assert Enum.sort(Map.keys(row)) ==
             Enum.sort([
               :id,
               :name,
               :slug,
               :url,
               :hashtag,
               :description,
               :window_starts_at,
               :window_ends_at,
               :status
             ])
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
