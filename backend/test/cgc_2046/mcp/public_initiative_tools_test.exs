defmodule Cgc2046.Mcp.PublicInitiativeToolsTest do
  use Cgc2046.DataCase, async: true

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule}
  alias Cgc2046.Mcp.Tools.{GetPublicInitiative, ListPublicInitiatives}

  @venue %{"country" => "中国", "province" => "湖南", "city" => "长沙", "district" => "岳麓"}

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

    detail_row = decode(detail)
    assert detail_row["slug"] == initiative.slug

    # 运营取投放链接的出口（Patch 3）：公开页绝对链接随工具结果返回，与
    # public_url/1 同值（相对路径 / 别的 base 都算不合格）
    assert detail_row["url"] == Cgc2046.Initiatives.Public.public_url(initiative.slug)
  end

  # #627：参与条件披露是**公开面**数据，MCP 是 peer 面而非特权面——两面的场次
  # 投影必须逐字同形（parity 断言防漂移；web/小程序消费同一份 Public 投影）。
  test "参与条件披露与 web 公开投影逐字同形（#627 parity）" do
    admin = Fixtures.platform_admin("mcp-public-initiative-parity")
    workspace = Fixtures.create_workspace(admin)
    initiative = open_initiative(admin, "mcp-public-parity")

    EventFixtures.create_event(workspace, admin, %{
      initiative_id: initiative.id,
      starts_at: DateTime.add(DateTime.utc_now(), 10, :day),
      ends_at: DateTime.add(DateTime.utc_now(), 11, :day),
      venue: @venue
    })

    frame = Frame.new(current_user: Fixtures.register_user("mcp-public-parity-outsider"))

    assert {:reply, _, _} =
             mcp_reply = GetPublicInitiative.execute(%{"slug" => initiative.slug}, frame)

    assert {:ok, payload} = Cgc2046.Initiatives.Public.get_by_slug(initiative.slug)

    mcp_row = decode(mcp_reply)["cities"] |> Enum.flat_map(& &1["events"]) |> hd()

    # 同一投影的线上形状比对（Elixir DTO 有 atom 键 / DateTime，先过 JSON 归一）
    public_row =
      payload.cities
      |> Enum.flat_map(& &1.events)
      |> hd()
      |> Jason.encode!()
      |> Jason.decode!()

    assert mcp_row == public_row,
           "MCP 与 web 公开投影漂移：mcp=#{inspect(mcp_row)}\npublic=#{inspect(public_row)}"

    # 参与条件四键逐字在场（防空断言空转）
    for key <- ["payment_mode", "deposit", "min_age", "price_range_min_cents"] do
      assert Map.has_key?(mcp_row, key), "MCP 场次投影缺参与条件键：#{key}"
    end
  end

  test "公开工具不泄露规则 value map / 锁态（#596 权限不扩大；#627 闸门精化）" do
    admin = Fixtures.platform_admin("mcp-public-privacy-admin")
    workspace = Fixtures.create_workspace(admin)
    initiative = open_initiative(admin, "mcp-public-privacy")

    # 场次是**必需的非空基座**：规则挂载后的事件快照键（min_age / deposit 明细）
    # 是公开事实，会被投影带出——闸门不能退化成「在空 payload 上恒真」。
    EventFixtures.create_event(workspace, admin, %{
      initiative_id: initiative.id,
      starts_at: DateTime.add(DateTime.utc_now(), 10, :day),
      ends_at: DateTime.add(DateTime.utc_now(), 11, :day),
      venue: @venue
    })

    frame = Frame.new(current_user: Fixtures.register_user("mcp-public-privacy-outsider"))

    assert {:reply, _, _} = list_reply = ListPublicInitiatives.execute(%{}, frame)

    row =
      Enum.find(decode(list_reply)["initiatives"], &(&1["slug"] == initiative.slug))

    refute Map.has_key?(row, "rules")
    refute Map.has_key?(row, "locked")
    refute Map.has_key?(row, "missing_rules")

    assert {:reply, %{content: [content]}, _} =
             GetPublicInitiative.execute(%{"slug" => initiative.slug}, frame)

    payload = Jason.decode!(content["text"])
    event_rows = payload["cities"] |> Enum.flat_map(& &1["events"])
    assert event_rows != []

    # 无歧义的治理标记/内部列名：逐字仍不得出现（不削弱 #596 原强度）
    for leak <- [
          "rules",
          "locked",
          "missing_rules",
          "value_json",
          "hours_before_start",
          "deadline_rule",
          "workspace_id",
          "capacity",
          "pricing_enabled",
          "deposit_enabled"
        ] do
      refute content["text"] =~ leak, "公开读面泄露了规则/内部信息：#{leak}"
    end

    # 规则原始 value map 的形状不得出现在任何层级。
    # #627 精化：判据从「键名字符串」改为「规则对象形状」——事件快照键 min_age /
    # deposit.amount_cents 是**规则效果已物化到 events.*** 的公开事实（裁决必须
    # 披露），规则对象 %{min_age: 18} / %{enabled: false} 本身仍永不出面。
    assert_no_rule_value_map(payload)
  end

  # 规则 value map 的键集形状（事件快照 map 的键集都比这些大或不同）
  @rule_value_key_sets [
    ["enabled"],
    ["amount_cents", "enabled"],
    ["min_age"],
    ["count"],
    ["hours_before_start"]
  ]

  defp assert_no_rule_value_map(value, path \\ "payload") do
    cond do
      is_map(value) ->
        keys = value |> Map.keys() |> Enum.sort()

        refute keys in @rule_value_key_sets,
               "公开读面泄露规则 value map：#{path} = #{inspect(value)}"

        Enum.each(value, fn {k, v} -> assert_no_rule_value_map(v, "#{path}.#{k}") end)

      is_list(value) ->
        value
        |> Enum.with_index()
        |> Enum.each(fn {v, i} -> assert_no_rule_value_map(v, "#{path}[#{i}]") end)

      true ->
        :ok
    end
  end
end
