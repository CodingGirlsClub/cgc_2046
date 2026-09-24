defmodule Cgc2046Web.GraphqlFlashbackWishEchoReadsTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.TokenCredential
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{WishEchoes, Wishes}
  alias Cgc2046.Repo

  defp post_graphql(query, variables) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query, "variables" => variables})
    |> json_response(200)
  end

  defp create_archive do
    Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: "echo-reads-#{System.unique_integer([:positive])}",
      name: "Rails Girls Beijing",
      city: "北京",
      occurred_on: ~D[2014-01-11]
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_person(archive) do
    Flashback.Person
    |> Ash.Changeset.for_create(:create, %{
      archive_event_id: archive.id,
      full_name: "王小明",
      surname: "王",
      city: "北京",
      participation: :attended,
      email: "echo-reads-#{System.unique_integer([:positive])}@example.test"
    })
    |> Ash.create!(authorize?: false)
  end

  defp issue_token(person) do
    plain = "echo-reads_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
    {:ok, hash} = TokenCredential.hash(plain)

    Flashback.Token
    |> Ash.Changeset.for_create(:create, %{person_id: person.id, token_hash: hash})
    |> Ash.create!(authorize?: false)

    plain
  end

  test "公开列表、公开直达和成员胶囊使用同一隐藏感知的白名单投影" do
    archive = create_archive()
    person = create_person(archive)
    token = issue_token(person)

    {:ok, wish} =
      Wishes.create_wish(person.id, "公开回响愿望", "public", public_listing_consent: true)

    {:ok, draft} = WishEchoes.create_draft(wish.id, "愿望回响正文")
    {:ok, echo} = WishEchoes.publish(draft.id, Ecto.UUID.generate())

    public_fields = """
    id
    content
    status
    publishedAt
    correctedAt
    """

    list_result =
      post_graphql(
        """
        query PublicList {
          flashbackPublicWishes(seed: "echo-reads", limit: 120) {
            id echoCount latestEcho { #{public_fields} }
            echoes { #{public_fields} }
          }
        }
        """,
        %{}
      )

    assert %{
             "data" => %{
               "flashbackPublicWishes" => [
                 %{
                   "id" => wish_id,
                   "echoCount" => 1,
                   "latestEcho" => %{
                     "id" => echo_id,
                     "content" => "愿望回响正文",
                     "status" => "published",
                     "publishedAt" => published_at,
                     "correctedAt" => nil
                   },
                   "echoes" => [list_echo]
                 }
                 | _
               ]
             }
           } = list_result

    assert wish_id == wish.id
    assert echo_id == echo.id
    assert list_echo["id"] == echo_id
    assert is_binary(published_at)

    direct_result =
      post_graphql(
        """
        query PublicWish($wishId: ID!) {
          flashbackPublicWish(wishId: $wishId) {
            id echoCount latestEcho { #{public_fields} } echoes { #{public_fields} }
          }
        }
        """,
        %{"wishId" => wish.id}
      )

    assert %{
             "data" => %{
               "flashbackPublicWish" => %{
                 "id" => ^wish_id,
                 "echoCount" => 1,
                 "latestEcho" => %{"id" => ^echo_id},
                 "echoes" => [%{"id" => ^echo_id}]
               }
             }
           } = direct_result

    capsule_result =
      post_graphql(
        """
        query Capsule($token: String!) {
          flashbackCapsule(token: $token) {
            publicWishes {
              id echoCount latestEcho { #{public_fields} } echoes { #{public_fields} }
            }
            myPrivateWishes { echoCount latestEcho { id } echoes { id } }
          }
        }
        """,
        %{"token" => token}
      )

    assert %{
             "data" => %{
               "flashbackCapsule" => %{
                 "publicWishes" => [
                   %{
                     "id" => ^wish_id,
                     "echoCount" => 1,
                     "latestEcho" => %{"id" => ^echo_id},
                     "echoes" => [%{"id" => ^echo_id}]
                   }
                 ],
                 "myPrivateWishes" => []
               }
             }
           } = capsule_result

    Repo.query!(
      "UPDATE flashback_wishes SET hidden_at = now() WHERE id = $1",
      [Repo.uuid!(wish.id)]
    )

    hidden_capsule =
      post_graphql(
        """
        query Capsule($token: String!) {
          flashbackCapsule(token: $token) {
            publicWishes { id echoCount latestEcho { id } echoes { id } }
          }
        }
        """,
        %{"token" => token}
      )

    assert %{
             "data" => %{
               "flashbackCapsule" => %{
                 "publicWishes" => [
                   %{"id" => ^wish_id, "echoCount" => 0, "latestEcho" => nil, "echoes" => []}
                 ]
               }
             }
           } = hidden_capsule

    hidden_public_wish =
      post_graphql(
        """
        query PublicWish($wishId: ID!) {
          flashbackPublicWish(wishId: $wishId) { id }
        }
        """,
        %{"wishId" => wish.id}
      )

    assert %{"data" => %{"flashbackPublicWish" => nil}} = hidden_public_wish
  end

  test "公开 Echo 类型不提供发布者或附议者身份字段" do
    result =
      post_graphql(
        """
        query ForbiddenEchoFields($wishId: ID!) {
          flashbackPublicWish(wishId: $wishId) {
            echoes { publishedByUserId endorsementId }
          }
        }
        """,
        %{"wishId" => Ecto.UUID.generate()}
      )

    assert [%{"message" => published_by_error}, %{"message" => endorsement_error}] =
             result["errors"]

    assert published_by_error =~ "publishedByUserId"
    assert endorsement_error =~ "endorsementId"
  end
end
