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

  defp open_initiative(admin) do
    {:ok, initiative} =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "GraphQL Initiative",
        slug: "gql-initiative",
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

    _private =
      EventsFixtures.create_event(workspace, admin, %{
        initiative_id: initiative.id,
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
end
