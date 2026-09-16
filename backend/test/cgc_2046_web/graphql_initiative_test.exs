defmodule Cgc2046Web.GraphqlInitiativeTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures
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

  defp open_initiative(admin, slug \\ "gql-initiative") do
    {:ok, initiative} =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "GraphQL Initiative",
        slug: slug,
        created_by: admin.id
      })
      |> Ash.create(actor: admin)

    for {key, value, locked} <- [
          {:deposit, %{enabled: true, amount_cents: 6900}, true},
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

  test "anonymous publicInitiative returns the same projection and filters workspace-only events" do
    admin = Fixtures.platform_admin("gql-initiative-admin")
    workspace = Fixtures.create_workspace(admin)
    initiative = open_initiative(admin)

    event =
      EventsFixtures.create_event(workspace, admin, %{
        initiative_id: initiative.id,
        starts_at: DateTime.add(DateTime.utc_now(), 10, :day),
        venue: %{"country" => "中国", "province" => "湖南", "city" => "长沙", "district" => "岳麓"},
        visibility: :public
      })

    # 押金规则锁定 ⇒ 挂载场必须落到非空 registration_deadline（自助取消锚点，
    # issue #587 的押金不变量），而 deadline_rule 快照要靠 starts_at 才能算出
    # 截止时间——不传 starts_at 的挂载场会被规则写入守卫拒绝（RuleInheritance）。
    # 本用例主体是「workspace-only 场被公开投影过滤」，时间字段不参与断言。
    _private =
      EventsFixtures.create_event(workspace, admin, %{
        initiative_id: initiative.id,
        starts_at: DateTime.add(DateTime.utc_now(), 11, :day),
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
end
