defmodule Cgc2046Web.GraphqlNotificationInboxTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Notifications.Notification

  require Ash.Query

  test "feed is private even for administrators and hostile OR filters" do
    owner = Fixtures.register_user("inbox-owner")
    other = Fixtures.platform_admin("inbox-other")
    mine = notification(owner, "a")
    theirs = notification(other, "b")

    assert %{"data" => %{"notificationFeed" => %{"results" => [row]}}} =
             graphql("{ notificationFeed { results { id title body readAt } } }", owner)

    assert row["id"] == mine.id
    assert row["title"] == "报名成功"
    assert row["readAt"] == nil

    assert %{"data" => %{"notificationFeed" => %{"results" => [admin_row]}}} =
             graphql("{ notificationFeed { results { id } } }", other)

    assert admin_row["id"] == theirs.id

    rows =
      Notification
      |> Ash.Query.filter(id == ^mine.id or id == ^theirs.id)
      |> Ash.read!(actor: owner, page: false)

    assert Enum.map(rows, & &1.id) == [mine.id]
  end

  test "anonymous feed is forbidden" do
    assert %{"errors" => [error | _]} = graphql("{ notificationFeed { results { id } } }", nil)
    assert error["code"] == "forbidden"
  end

  test "read mark is idempotent and cannot target another account or expired record" do
    owner = Fixtures.register_user("inbox-mark-owner")
    other = Fixtures.register_user("inbox-mark-other")
    mine = notification(owner, "mark-a")
    expired = notification(owner, "mark-expired")

    Cgc2046.Repo.query!("UPDATE notifications SET inserted_at = $1 WHERE id = $2", [
      DateTime.utc_now() |> DateTime.add(-31, :day) |> DateTime.to_naive(),
      expired.id
    ])

    mutation =
      "mutation { markNotificationRead(id: \"#{mine.id}\") { result { id readAt } errors { code } } }"

    assert %{"data" => %{"markNotificationRead" => %{"result" => first, "errors" => []}}} =
             graphql(mutation, owner)

    assert first["id"] == mine.id
    assert is_binary(first["readAt"])

    assert %{"data" => %{"markNotificationRead" => %{"result" => ^first, "errors" => []}}} =
             graphql(mutation, owner)

    for {id, actor} <- [{mine.id, other}, {expired.id, owner}, {"missing", owner}] do
      denied =
        "mutation { markNotificationRead(id: \"#{id}\") { result { id } errors { code } } }"

      assert %{"data" => %{"markNotificationRead" => %{"result" => nil, "errors" => [error | _]}}} =
               graphql(denied, actor)

      assert error["code"] == "not_found"
    end

    assert %{"data" => %{"notificationFeed" => %{"results" => [row]}}} =
             graphql("{ notificationFeed { results { id } } }", owner)

    assert row["id"] == mine.id
  end

  test "stable keysets survive new arrivals and reject public filters" do
    user = Fixtures.register_user("inbox-pages")
    for id <- ["page-c", "page-a", "page-b"], do: notification(user, id)

    Cgc2046.Repo.query!("UPDATE notifications SET inserted_at = $1 WHERE user_id = $2", [
      DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_naive(),
      Cgc2046.Repo.uuid!(user.id)
    ])

    assert %{"data" => %{"notificationFeed" => %{"results" => rows, "endKeyset" => cursor}}} =
             graphql("{ notificationFeed(first: 2) { results { id } endKeyset } }", user)

    assert Enum.map(rows, & &1["id"]) == ["page-a", "page-b"]
    notification(user, "new-arrival")

    assert %{"data" => %{"notificationFeed" => %{"results" => [%{"id" => "page-c"}]}}} =
             graphql(
               "{ notificationFeed(first: 2, after: \"#{cursor}\") { results { id } } }",
               user
             )

    assert %{"errors" => [_ | _]} =
             graphql("{ notificationFeed(filter: {or: []}) { results { id } } }", user)

    for n <- 1..55, do: notification(user, "extra-#{n}")

    assert %{"data" => %{"notificationFeed" => %{"results" => capped}}} =
             graphql("{ notificationFeed(first: 100) { results { id } } }", user)

    assert length(capped) == 50

    assert %{"errors" => [_ | _]} =
             graphql("{ notificationFeed(after: \"malformed\") { results { id } } }", user)
  end

  defp notification(user, id) do
    Notification
    |> Ash.Changeset.for_create(:record, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attributes(%{
      id: id,
      user_id: user.id,
      type: "enrollment_completed",
      payload: %{"title" => "报名成功", "body" => "你的报名已确认。"}
    })
    |> Ash.create!()
  end

  defp graphql(query, nil) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end

  defp graphql(query, user) do
    login =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{
        "query" =>
          "mutation { signIn(login: \"#{user.email}\", password: \"#{Fixtures.password()}\") { id } }"
      })

    assert %{"data" => %{"signIn" => %{"id" => _}}} = json_response(login, 200)

    build_conn()
    |> put_req_header("authorization", "Bearer #{login.resp_cookies["cgc_token"].value}")
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end
end
