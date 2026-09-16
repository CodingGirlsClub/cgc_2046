defmodule Cgc2046Web.GraphqlInitiativeTest do
  use Cgc2046Web.ConnCase, async: true

  require Ash.Query

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures
  alias Cgc2046.Events.Event
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule}

  defp post_graphql(query, token \\ nil) do
    conn = build_conn() |> put_req_header("content-type", "application/json")
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    conn |> post("/api/graphql", %{"query" => query}) |> json_response(200)
  end

  defp token(user) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{
        "query" =>
          "mutation { signIn(login: \"#{user.email}\", password: \"#{Fixtures.password()}\") { id } }"
      })

    conn.resp_cookies["cgc_token"].value
  end

  # develop 侧的 (admin) / (admin, slug) 调用 + #595 侧的 (admin, slug, deposit) 调用统一支持
  defp open_initiative(admin, slug \\ "gql-initiative"),
    do: open_initiative(admin, slug, %{enabled: true, amount_cents: 6900})

  defp open_initiative(admin, slug, deposit_value) do
    {:ok, initiative} =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "GraphQL Initiative",
        slug: slug,
        created_by: admin.id
      })
      |> Ash.create(actor: admin)

    for {key, value, locked} <- [
          {:deposit, deposit_value, true},
          {:age_gate, %{min_age: 18}, true},
          {:min_participants, %{count: 8}, false},
          {:deadline_rule, %{hours_before_start: 72}, false}
        ] do
      assert {:ok, _} =
               InitiativeRule
               |> Ash.Changeset.for_create(:create, %{
                 initiative_id: initiative.id,
                 key: key,
                 value: value,
                 locked: locked
               })
               |> Ash.create(actor: admin)
    end

    assert {:ok, initiative} =
             initiative |> Ash.Changeset.for_update(:open, %{}) |> Ash.update(actor: admin)

    initiative
  end

  # 挂载要求 Event 为 draft；EventsFixtures.create_event/3 会 force_open，故此处
  # 自带草稿布置（同 InitiativeBoundaryTest.draft_event/3 的理由）。
  defp mounted_draft_event(workspace, admin, attrs) do
    # KTD6：两值同时存在时 ends_at 须严格晚于 starts_at（只填一个合法）→
    # 默认 ends_at 跟随 starts_at 派生，显式传入的 ends_at 优先。
    starts_at = Map.get(attrs, :starts_at, DateTime.add(DateTime.utc_now(), 10, :day))

    attrs =
      attrs
      |> Map.put_new(:title, "Mounted Draft")
      |> Map.put_new(:enrollment_policy, :open)
      |> Map.put(:starts_at, starts_at)
      |> Map.put_new(:ends_at, if(starts_at, do: DateTime.add(starts_at, 1, :day)))

    Event
    |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: admin)
  end

  # events.confirmed_count 是账本同步的展示投影列；直接用 SQL 钉一个非零真值，
  # 证明读面取的是 DB 真值而非常量（同 EventsFixtures.force_open 的裸 SQL 手法）。
  defp seed_confirmed_count(event, count) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE events SET confirmed_count = $1 WHERE id = $2",
        [count, Ecto.UUID.dump!(event.id)]
      )

    :ok
  end

  test "anonymous publicInitiative returns the same projection and filters workspace-only events" do
    admin = Fixtures.platform_admin("gql-initiative-admin")
    workspace = Fixtures.create_workspace(admin)
    initiative = open_initiative(admin)

    event =
      EventsFixtures.create_event(workspace, admin, %{
        initiative_id: initiative.id,
        starts_at: DateTime.add(DateTime.utc_now(), 10, :day),
        ends_at: DateTime.add(DateTime.utc_now(), 11, :day),
        venue: %{"country" => "中国", "province" => "湖南", "city" => "长沙", "district" => "岳麓"},
        visibility: :public
      })

    # 押金规则锁定 ⇒ 挂载场必须落到非空 registration_deadline（自助取消锚点，
    # issue #587 的押金不变量）与非空 ends_at（no-show 结算锚点，#608 DB CHECK
    # events_deposit_requires_ends_at），而 deadline_rule 快照要靠 starts_at 才能
    # 算出截止时间——不传 starts_at / ends_at 的挂载场会被规则写入守卫或 DB CHECK
    # 拒绝（RuleInheritance / Event.handle_write_error）。
    # 本用例主体是「workspace-only 场被公开投影过滤」，时间字段不参与断言。
    _private =
      EventsFixtures.create_event(workspace, admin, %{
        initiative_id: initiative.id,
        starts_at: DateTime.add(DateTime.utc_now(), 11, :day),
        ends_at: DateTime.add(DateTime.utc_now(), 12, :day),
        visibility: :workspace
      })

    query = """
    query { publicInitiative(slug: "#{initiative.slug}") {
      slug eventCount cityCount cities { city events { id slug status startsAt registrationDeadline venue archived qualificationBadge } }
    } }
    """

    assert %{"data" => %{"publicInitiative" => payload}} = post_graphql(query)
    assert payload["slug"] == initiative.slug
    assert payload["eventCount"] == 1

    assert [%{"city" => "长沙", "events" => [row]}] = payload["cities"]
    assert row["id"] == event.id
    assert {:ok, _, _} = DateTime.from_iso8601(row["startsAt"])
    assert {:ok, _, _} = DateTime.from_iso8601(row["registrationDeadline"])
    assert is_binary(row["venue"])
    assert row["archived"] == false
    assert is_binary(row["qualificationBadge"])
  end

  # #628：中止入口（GraphQL 面）——终态迁移 + 稳定状态串
  test "admin cancelInitiative 把 open 活动迁到 cancelled，并对二次调用拒绝" do
    admin = Fixtures.platform_admin("gql-initiative-cancel-admin")
    initiative = open_initiative(admin, "gql-initiative-cancel")

    mutation =
      "mutation { cancelInitiative(id: \"#{initiative.id}\") { result { id status } errors { code message } } }"

    assert %{"data" => %{"cancelInitiative" => %{"result" => result, "errors" => []}}} =
             post_graphql(mutation, token(admin))

    assert result["status"] == "cancelled"
    assert Ash.get!(Initiative, initiative.id, authorize?: false).status == :cancelled

    # 终态不可逆：二次调用回错误信封而非再次迁移
    assert %{"data" => %{"cancelInitiative" => %{"result" => nil, "errors" => [_ | _]}}} =
             post_graphql(mutation, token(admin))
  end

  test "platform admin listInitiatives is protected and returns rows" do
    admin = Fixtures.platform_admin("gql-initiative-list-admin")
    initiative = open_initiative(admin)

    query =
      "query { listInitiatives(status: \"open\") { id slug status rules { id key valueJson locked } } }"

    assert %{"errors" => [%{"code" => "unauthorized"}]} = post_graphql(query)

    assert %{"data" => %{"listInitiatives" => rows}} = post_graphql(query, token(admin))
    row = Enum.find(rows, &(&1["id"] == initiative.id))
    assert row["status"] == "open"

    assert length(row["rules"]) == 4

    assert Enum.all?(row["rules"], fn rule ->
             is_binary(rule["id"]) and is_binary(rule["key"]) and
               is_binary(rule["valueJson"]) and is_boolean(rule["locked"])
           end)
  end

  test "platform admin upsertInitiativeRule rejects unknown key with invalid_input payload error" do
    admin = Fixtures.platform_admin("gql-initiative-rule-admin")
    initiative = open_initiative(admin)

    query = """
    mutation {
      upsertInitiativeRule(initiativeId: "#{initiative.id}", key: "bogus", valueJson: "{}", locked: false) {
        result { id }
        errors { message code }
      }
    }
    """

    assert %{"data" => %{"upsertInitiativeRule" => payload}} = post_graphql(query, token(admin))
    assert payload["result"] == nil
    assert [%{"message" => "invalid rule key", "code" => "invalid_input"}] = payload["errors"]
  end

  test "platform admin upsertInitiativeRule creates then updates a rule for a known key" do
    admin = Fixtures.platform_admin("gql-initiative-rule-admin")

    {:ok, initiative} =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "GraphQL Initiative Rule",
        slug: "gql-initiative-rule",
        created_by: admin.id
      })
      |> Ash.create(actor: admin)

    create_query = """
    mutation {
      upsertInitiativeRule(initiativeId: "#{initiative.id}", key: "deposit", valueJson: "{\\"enabled\\":true,\\"amount_cents\\":6900}", locked: true) {
        result { id key valueJson locked }
        errors { message code }
      }
    }
    """

    assert %{"data" => %{"upsertInitiativeRule" => created}} =
             post_graphql(create_query, token(admin))

    assert created["errors"] == []
    assert created["result"]["key"] == "deposit"
    assert created["result"]["locked"] == true

    assert Jason.decode!(created["result"]["valueJson"]) == %{
             "enabled" => true,
             "amount_cents" => 6900
           }

    update_query = """
    mutation {
      upsertInitiativeRule(initiativeId: "#{initiative.id}", key: "deposit", valueJson: "{\\"enabled\\":false}", locked: false) {
        result { id key valueJson locked }
        errors { message code }
      }
    }
    """

    assert %{"data" => %{"upsertInitiativeRule" => updated}} =
             post_graphql(update_query, token(admin))

    assert updated["errors"] == []
    assert updated["result"]["id"] == created["result"]["id"]
    assert updated["result"]["locked"] == false
    assert Jason.decode!(updated["result"]["valueJson"]) == %{"enabled" => false}
  end

  describe "updateInitiative slug 锁定（#588）" do
    test "open Initiative 改 slug → errors 带稳定 code initiative_slug_locked" do
      admin = Fixtures.platform_admin("gql-init-lock")
      initiative = open_initiative(admin, "gql-init-lock-open")

      query = """
      mutation {
        updateInitiative(id: "#{initiative.id}", input: {slug: "gql-init-lock-renamed"}) {
          result { id slug }
          errors { message code }
        }
      }
      """

      assert %{"data" => %{"updateInitiative" => payload}} = post_graphql(query, token(admin))
      assert payload["result"] == nil
      assert [%{"code" => "initiative_slug_locked", "message" => message}] = payload["errors"]
      assert message =~ "slug is locked"

      assert Ash.get!(Initiative, initiative.id, authorize?: false).slug == "gql-init-lock-open"
    end

    test "open Initiative 只改 name 且 slug 原样回传 → 成功（web 表单 payload 形状回归）" do
      admin = Fixtures.platform_admin("gql-init-keep")
      initiative = open_initiative(admin, "gql-init-keep")

      query = """
      mutation {
        updateInitiative(id: "#{initiative.id}", input: {name: "改过的名字", slug: "#{initiative.slug}"}) {
          result { id name slug }
          errors { message code }
        }
      }
      """

      assert %{"data" => %{"updateInitiative" => payload}} = post_graphql(query, token(admin))
      assert payload["errors"] == []
      assert payload["result"]["name"] == "改过的名字"
      assert payload["result"]["slug"] == "gql-init-keep"
    end

    test "draft Initiative 改 slug → 成功" do
      admin = Fixtures.platform_admin("gql-init-draft")

      {:ok, draft} =
        Initiative
        |> Ash.Changeset.for_create(:create, %{
          name: "GraphQL Draft",
          slug: "gql-init-draft",
          created_by: admin.id
        })
        |> Ash.create(actor: admin)

      query = """
      mutation {
        updateInitiative(id: "#{draft.id}", input: {slug: "gql-init-draft-2"}) {
          result { id slug status }
          errors { message code }
        }
      }
      """

      assert %{"data" => %{"updateInitiative" => payload}} = post_graphql(query, token(admin))
      assert payload["errors"] == []
      assert payload["result"]["slug"] == "gql-init-draft-2"
      assert payload["result"]["status"] == "draft"
    end
  end

  # #596 挂载前预览：Owner/Admin 可读四规则值与锁态；普通成员/匿名不可见
  test "initiativeMountPreview：Owner 可读，普通成员 forbidden，匿名 unauthorized" do
    admin = Fixtures.platform_admin("gql-mount-preview-admin")
    initiative = open_initiative(admin)
    %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()

    query = """
    query { initiativeMountPreview(workspaceId: "#{workspace.id}", initiativeId: "#{initiative.id}") {
      initiativeId name slug status missingRules
      rules { key valueJson locked }
    } }
    """

    assert %{"data" => %{"initiativeMountPreview" => preview}} =
             post_graphql(query, token(owner))

    assert preview["initiativeId"] == initiative.id
    assert preview["status"] == "open"
    assert preview["missingRules"] == []

    assert preview["rules"] == [
             %{
               "key" => "deposit",
               "valueJson" => Jason.encode!(%{"enabled" => true, "amount_cents" => 6900}),
               "locked" => true
             },
             %{
               "key" => "age_gate",
               "valueJson" => Jason.encode!(%{"min_age" => 18}),
               "locked" => true
             },
             %{
               "key" => "min_participants",
               "valueJson" => Jason.encode!(%{"count" => 8}),
               "locked" => false
             },
             %{
               "key" => "deadline_rule",
               "valueJson" => Jason.encode!(%{"hours_before_start" => 72}),
               "locked" => false
             }
           ]

    assert %{"errors" => [%{"code" => "forbidden"}]} = post_graphql(query, token(member))
    assert %{"errors" => [%{"code" => "unauthorized"}]} = post_graphql(query)

    # 非成员（已登录）与非成员平台管理员同样 forbidden（该面无 platform_admin 豁免）
    outsider = Fixtures.register_user("gql-mount-preview-outsider")
    assert %{"errors" => [%{"code" => "forbidden"}]} = post_graphql(query, token(outsider))
    assert %{"errors" => [%{"code" => "forbidden"}]} = post_graphql(query, token(admin))
  end

  # #596 SDL 结构守卫：公开 Initiative 类型不得长出 rules 字段（权限不扩大的结构性防线）
  test "公开 Initiative 类型不含 rules 字段（SDL 冻结）" do
    sdl = File.read!("priv/graphql/schema.graphql")

    for type <- ["PublicInitiative", "PublicInitiativeCard"] do
      fields = sdl_type_fields(sdl, type)
      assert fields != [], "SDL 中找不到 #{type}"
      refute "rules" in fields
      refute "locked" in fields
    end
  end

  defp sdl_type_fields(sdl, name) do
    case Regex.run(~r/^type #{name}\b[^{]*\{(.*?)^\}/ms, sdl, capture: :all_but_first) do
      [body] ->
        ~r/^\s{2}([A-Za-z_][A-Za-z0-9_]*)\s*[:(]/m
        |> Regex.scan(body, capture: :all_but_first)
        |> List.flatten()

      _ ->
        []
    end
  end

  # ---- #595 挂载场读面 + 拒绝路径 fields（D1 / D4） ----
  # 契约测试的字段断言是「与后端真值一致」的钉子：Event 上锁死规则的传播结果、
  # Workspace join、confirmed_count 投影列都在这里钉死。

  @mounted_event_fields "id initiativeId slug title status startsAt registrationDeadline venue workspaceId workspaceName confirmedCount pricingEnabled depositEnabled depositAmountCents minAge minParticipants"

  test "platform admin getInitiative returns every mounted event with workspace truth" do
    admin = Fixtures.platform_admin("gql-mounts-admin")
    workspace_a = Fixtures.create_workspace(admin)
    workspace_b = Fixtures.create_workspace(admin)
    initiative = open_initiative(admin, "gql-mounts", %{enabled: true, amount_cents: 6900})

    starts_at = DateTime.add(DateTime.utc_now(), 10, :day) |> DateTime.truncate(:second)

    public_event =
      mounted_draft_event(workspace_a, admin, %{
        initiative_id: initiative.id,
        title: "Public Mounted",
        starts_at: starts_at,
        visibility: :public,
        venue: %{
          "country" => "中国",
          "province" => "湖南",
          "city" => "长沙",
          "district" => "岳麓"
        }
      })

    # workspace-only 场同样会被锁死规则改写 → 清单必须包含它（刻意不过滤 visibility）
    internal_event =
      mounted_draft_event(workspace_b, admin, %{
        initiative_id: initiative.id,
        title: "Internal Mounted",
        starts_at: DateTime.add(DateTime.utc_now(), 20, :day),
        visibility: :workspace
      })

    :ok = seed_confirmed_count(public_event, 7)

    query = """
    query {
      getInitiative(id: "#{initiative.id}") {
        id
        mountedEvents { #{@mounted_event_fields} }
      }
    }
    """

    assert %{"data" => %{"getInitiative" => payload}} = post_graphql(query, token(admin))
    assert payload["id"] == initiative.id
    assert length(payload["mountedEvents"]) == 2

    public_row = Enum.find(payload["mountedEvents"], &(&1["id"] == public_event.id))
    internal_row = Enum.find(payload["mountedEvents"], &(&1["id"] == internal_event.id))

    assert public_row["initiativeId"] == initiative.id
    assert public_row["slug"] == public_event.slug
    assert public_row["title"] == "Public Mounted"
    assert public_row["status"] == "draft"
    assert public_row["startsAt"] == DateTime.to_iso8601(starts_at)
    # 锁死 deadline_rule（72h）在挂载时已写进 registration_deadline
    assert public_row["registrationDeadline"] ==
             DateTime.add(starts_at, -72 * 3600, :second) |> DateTime.to_iso8601()

    assert Jason.decode!(public_row["venue"]) == %{
             "country" => "中国",
             "province" => "湖南",
             "city" => "长沙",
             "district" => "岳麓"
           }

    assert public_row["workspaceId"] == workspace_a.id
    assert public_row["workspaceName"] == workspace_a.name
    assert public_row["confirmedCount"] == 7
    assert public_row["pricingEnabled"] == false
    assert public_row["depositEnabled"] == true
    assert public_row["depositAmountCents"] == 6900
    assert public_row["minAge"] == 18
    assert public_row["minParticipants"] == 8

    assert internal_row["status"] == "draft"
    assert internal_row["workspaceId"] == workspace_b.id
    assert internal_row["workspaceName"] == workspace_b.name
    assert internal_row["confirmedCount"] == 0
  end

  test "mountedEvents are ordered by starts_at NULLS LAST then inserted_at, id" do
    admin = Fixtures.platform_admin("gql-mounts-order-admin")
    workspace = Fixtures.create_workspace(admin)
    initiative = open_initiative(admin, "gql-mounts-order", %{enabled: false, amount_cents: nil})

    # 插入顺序刻意与 starts_at 顺序相反，证明排序不是 fallback 到扫描顺序
    late =
      mounted_draft_event(workspace, admin, %{
        initiative_id: initiative.id,
        title: "Late",
        starts_at: DateTime.add(DateTime.utc_now(), 20, :day)
      })

    undated =
      mounted_draft_event(workspace, admin, %{
        initiative_id: initiative.id,
        title: "Undated",
        starts_at: nil
      })

    early =
      mounted_draft_event(workspace, admin, %{
        initiative_id: initiative.id,
        title: "Early",
        starts_at: DateTime.add(DateTime.utc_now(), 10, :day)
      })

    query = """
    query { getInitiative(id: "#{initiative.id}") { mountedEvents { id } } }
    """

    assert %{"data" => %{"getInitiative" => %{"mountedEvents" => rows}}} =
             post_graphql(query, token(admin))

    assert Enum.map(rows, & &1["id"]) == [early.id, late.id, undated.id]
  end

  test "mountedEvents is empty when nothing is mounted" do
    admin = Fixtures.platform_admin("gql-mounts-empty-admin")
    initiative = open_initiative(admin, "gql-mounts-empty", %{enabled: false, amount_cents: nil})

    query = """
    query { getInitiative(id: "#{initiative.id}") { mountedEvents { id } } }
    """

    assert %{"data" => %{"getInitiative" => %{"mountedEvents" => []}}} =
             post_graphql(query, token(admin))
  end

  # F8/R3：附挂读面失败 → mountedEvents = null（不是 []，也不是打掉详情的顶层错误）。
  # 故障确定性注入：把 events 改名（DDL 在 sandbox 事务内，测试结束自动回滚）。
  test "mountedEvents is null on projection failure and does not break the detail read" do
    admin = Fixtures.platform_admin("gql-mounts-fail-admin")
    initiative = open_initiative(admin, "gql-mounts-fail", %{enabled: false, amount_cents: nil})

    Ecto.Adapters.SQL.query!(Cgc2046.Repo, "ALTER TABLE events RENAME TO events_hidden_595")

    query = """
    query {
      getInitiative(id: "#{initiative.id}") { id rules { key } mountedEvents { id } }
    }
    """

    response = post_graphql(query, token(admin))
    assert %{"data" => %{"getInitiative" => payload}} = response
    assert payload["id"] == initiative.id
    # 主读不受影响：规则照常返回
    assert length(payload["rules"]) == 4
    # 附挂读面明确"不可用"，与"真的 0 场"区分开
    assert payload["mountedEvents"] == nil
    assert Map.get(response, "errors", []) == []
  end

  test "mountedEvents is platform-admin only" do
    admin = Fixtures.platform_admin("gql-mounts-gate-admin")
    member = Fixtures.register_user("gql-mounts-gate-member")
    initiative = open_initiative(admin, "gql-mounts-gate", %{enabled: false, amount_cents: nil})

    query = """
    query { getInitiative(id: "#{initiative.id}") { mountedEvents { id workspaceName } } }
    """

    assert %{"errors" => [%{"code" => "unauthorized"}]} = post_graphql(query)
    assert %{"errors" => [%{"code" => "forbidden"}]} = post_graphql(query, token(member))

    assert %{"data" => %{"getInitiative" => %{"mountedEvents" => []}}} =
             post_graphql(query, token(admin))
  end

  # D4：规则被拒时 fields 必须带上「是哪个场」（canonical UUID，非裸 SQL 的
  # 16 字节 binary），前端据此翻成「场 + 工作台」。
  test "upsertInitiativeRule deposit conflict returns event_id in payload error fields" do
    admin = Fixtures.platform_admin("gql-rule-fields-admin")
    workspace = Fixtures.create_workspace(admin)

    # 押金规则先关闭（否则开定价的场根本挂不进来），挂载后再开定价
    initiative = open_initiative(admin, "gql-rule-fields", %{enabled: false, amount_cents: nil})

    event =
      mounted_draft_event(workspace, admin, %{
        initiative_id: initiative.id,
        title: "Priced Mounted",
        starts_at: DateTime.add(DateTime.utc_now(), 10, :day)
      })

    assert {:ok, priced} =
             event
             |> Ash.Changeset.for_update(:update, %{
               pricing_enabled: true,
               price_tiers: [
                 %{"id" => Ash.UUID.generate(), "name" => "标准", "amount_cents" => 19_900}
               ]
             })
             |> Ash.update(actor: admin, tenant: workspace.id)

    assert priced.pricing_enabled == true

    query = """
    mutation {
      upsertInitiativeRule(initiativeId: "#{initiative.id}", key: "deposit", valueJson: "{\\"enabled\\":true,\\"amount_cents\\":6900}", locked: true) {
        result { id }
        errors { message code fields }
      }
    }
    """

    assert %{"data" => %{"upsertInitiativeRule" => payload}} = post_graphql(query, token(admin))
    assert payload["result"] == nil

    assert [%{"code" => "event_payment_mode_exclusive", "fields" => fields} = error] =
             payload["errors"]

    assert fields == ["event_id=#{event.id}"]
    assert error["message"] =~ "disable pricing"

    # 整次更新被拒 → 规则行与场配置都不变
    rule =
      InitiativeRule
      |> Ash.Query.filter(initiative_id == ^initiative.id and key == :deposit)
      |> Ash.read_one!(actor: admin)

    assert rule.value == %{"enabled" => false, "amount_cents" => nil}

    reloaded = Ash.get!(Event, event.id, authorize?: false, tenant: workspace.id)
    assert reloaded.pricing_enabled == true
    assert reloaded.deposit_enabled == false
  end
end
