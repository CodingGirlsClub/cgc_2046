defmodule Cgc2046Web.GraphqlFlashbackProgressTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.TokenCredential
  alias Cgc2046.Flashback.{EventArchive, Person, Token}

  @moduletag :capture_log

  test "enter 的真实 GraphQL 载荷区分未收好与已有主人" do
    archive =
      EventArchive
      |> Ash.Changeset.for_create(:create, %{
        key: "progress-bound-test",
        name: "Progress fixture",
        city: "上海",
        occurred_on: ~D[2014-01-11]
      })
      |> Ash.create!(authorize?: false)

    for bound <- [false, true] do
      person =
        Person
        |> Ash.Changeset.for_create(:create, %{
          full_name: "测试",
          surname: "测",
          role: :learner,
          participation: :attended,
          archive_event_id: archive.id
        })
        |> Ash.create!(authorize?: false)

      if bound do
        user = Cgc2046.AccountsFixtures.register_user("progress-bound")

        person
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:user_id, user.id)
        |> Ash.update!(authorize?: false)
      end

      plain = "fb_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      {:ok, hash} = TokenCredential.hash(plain)

      Token
      |> Ash.Changeset.for_create(:create, %{person_id: person.id, token_hash: hash})
      |> Ash.create!(authorize?: false)

      response =
        build_conn()
        |> post("/api/graphql", %{
          "query" =>
            "mutation($token: String!) { flashbackEnter(token: $token) { progress { bound } } }",
          "variables" => %{"token" => plain}
        })
        |> json_response(200)

      refute Map.has_key?(response, "errors")
      assert get_in(response, ["data", "flashbackEnter", "progress", "bound"]) == bound
    end
  end
end
