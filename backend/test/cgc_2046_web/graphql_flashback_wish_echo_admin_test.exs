defmodule Cgc2046Web.GraphqlFlashbackWishEchoAdminTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.Wishes

  @moduletag :capture_log

  defp post_graphql(query, variables), do: post_graphql(query, variables, nil)

  defp post_graphql(query, variables, user) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")

    conn =
      if user do
        put_req_header(conn, "authorization", "Bearer #{sign_in_token(user)}")
      else
        conn
      end

    conn
    |> post("/api/graphql", %{"query" => query, "variables" => variables})
    |> json_response(200)
  end

  defp sign_in_token(user) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/api/graphql",
        %{
          "query" =>
            ~s'mutation { signIn(login: "#{user.email}", password: "#{AccountsFixtures.password()}") { id } }'
        }
      )

    conn.resp_cookies["cgc_token"].value
  end

  defp create_listed_wish do
    archive =
      Flashback.EventArchive
      |> Ash.Changeset.for_create(:create, %{
        key: "echo-admin-#{System.unique_integer([:positive])}",
        name: "Rails Girls Beijing",
        city: "北京",
        occurred_on: ~D[2014-01-11]
      })
      |> Ash.create!(authorize?: false)

    person =
      Flashback.Person
      |> Ash.Changeset.for_create(:create, %{
        archive_event_id: archive.id,
        full_name: "王小明",
        surname: "王",
        city: "北京",
        participation: :attended,
        email: "echo-admin-#{System.unique_integer([:positive])}@example.test"
      })
      |> Ash.create!(authorize?: false)

    {:ok, wish} =
      Wishes.create_wish(person.id, "公开树愿望", "public", public_listing_consent: true)

    Cgc2046.FlashbackFixtures.list_wish!(wish.id)
    Ash.get!(Cgc2046.Flashback.Wish, wish.id, authorize?: false)
  end

  defp create_unlisted_wish do
    archive =
      Flashback.EventArchive
      |> Ash.Changeset.for_create(:create, %{
        key: "echo-unlisted-#{System.unique_integer([:positive])}",
        name: "Rails Girls Beijing",
        city: "北京",
        occurred_on: ~D[2014-01-11]
      })
      |> Ash.create!(authorize?: false)

    person =
      Flashback.Person
      |> Ash.Changeset.for_create(:create, %{
        archive_event_id: archive.id,
        full_name: "王小明",
        surname: "王",
        city: "北京",
        participation: :attended,
        email: "echo-unlisted-#{System.unique_integer([:positive])}@example.test"
      })
      |> Ash.create!(authorize?: false)

    {:ok, wish} = Wishes.create_wish(person.id, "尚未挂树愿望", "public")
    wish
  end

  defp create_draft_mutation do
    """
    mutation CreateWishEcho($wishId: ID!, $content: String!) {
      flashbackAdminCreateWishEcho(wishId: $wishId, content: $content) {
        id content status
      }
    }
    """
  end

  test "PlatformAdmin can manage the explicit lifecycle and the admin query stays private" do
    admin = AccountsFixtures.platform_admin("wish-echo-admin")
    regular_user = AccountsFixtures.register_user("wish-echo-user")
    wish = create_listed_wish()
    {:ok, _endorsement} = Wishes.endorse_by_user(regular_user.id, wish.id, notify: true)

    query = """
    query WishEchoes($wishId: ID!) {
      flashbackAdminWishEchoes(wishId: $wishId) {
        currentNotifiableEndorsementCount
        echoes {
          id content status insertedAt publishedAt correctedAt revokedAt publishedByUserId
        }
      }
    }
    """

    assert [%{"code" => "unauthorized"}] =
             post_graphql(query, %{"wishId" => wish.id})["errors"]

    assert [%{"code" => "forbidden"}] =
             post_graphql(query, %{"wishId" => wish.id}, regular_user)["errors"]

    assert %{
             "data" => %{
               "flashbackAdminWishEchoes" => %{
                 "currentNotifiableEndorsementCount" => 1,
                 "echoes" => []
               }
             }
           } = post_graphql(query, %{"wishId" => wish.id}, admin)

    assert %{
             "data" => %{
               "flashbackAdminCreateWishEcho" => %{
                 "id" => echo_id,
                 "content" => "首条回应",
                 "status" => "draft"
               }
             }
           } =
             post_graphql(
               create_draft_mutation(),
               %{"wishId" => wish.id, "content" => "  首条回应  "},
               admin
             )

    assert [%{"code" => "flashback_wish_echo_invalid_transition"}] =
             post_graphql(
               """
               mutation CorrectDraft($echoId: ID!, $content: String!) {
                 flashbackAdminCorrectWishEcho(echoId: $echoId, content: $content) {
                   id status
                 }
               }
               """,
               %{"echoId" => echo_id, "content" => "不能越级发布"},
               admin
             )["errors"]

    assert %{
             "data" => %{
               "flashbackAdminUpdateWishEchoDraft" => %{
                 "id" => ^echo_id,
                 "content" => "草稿已修改",
                 "status" => "draft"
               }
             }
           } =
             post_graphql(
               """
               mutation UpdateDraft($echoId: ID!, $content: String!) {
                 flashbackAdminUpdateWishEchoDraft(echoId: $echoId, content: $content) {
                   id content status
                 }
               }
               """,
               %{"echoId" => echo_id, "content" => "  草稿已修改  "},
               admin
             )

    assert %{
             "data" => %{
               "flashbackAdminPublishWishEcho" => %{
                 "id" => ^echo_id,
                 "status" => "published",
                 "publishedAt" => published_at,
                 "publishedByUserId" => published_by_user_id
               }
             }
           } =
             post_graphql(
               """
               mutation Publish($echoId: ID!) {
                 flashbackAdminPublishWishEcho(echoId: $echoId) {
                   id status publishedAt publishedByUserId
                 }
               }
               """,
               %{"echoId" => echo_id},
               admin
             )

    assert is_binary(published_at)
    assert published_by_user_id == admin.id

    assert [%{"code" => "flashback_wish_echo_invalid_transition"}] =
             post_graphql(
               """
               mutation PublishAgain($echoId: ID!) {
                 flashbackAdminPublishWishEcho(echoId: $echoId) { id status }
               }
               """,
               %{"echoId" => echo_id},
               admin
             )["errors"]

    assert %{
             "data" => %{
               "flashbackAdminCorrectWishEcho" => %{
                 "id" => ^echo_id,
                 "content" => "已更正的回应",
                 "status" => "corrected",
                 "correctedAt" => corrected_at
               }
             }
           } =
             post_graphql(
               """
               mutation Correct($echoId: ID!, $content: String!) {
                 flashbackAdminCorrectWishEcho(echoId: $echoId, content: $content) {
                   id content status correctedAt
                 }
               }
               """,
               %{"echoId" => echo_id, "content" => "已更正的回应"},
               admin
             )

    assert is_binary(corrected_at)

    assert %{
             "data" => %{
               "flashbackAdminRevokeWishEcho" => %{
                 "id" => ^echo_id,
                 "status" => "revoked",
                 "revokedAt" => revoked_at
               }
             }
           } =
             post_graphql(
               """
               mutation Revoke($echoId: ID!) {
                 flashbackAdminRevokeWishEcho(echoId: $echoId) {
                   id status revokedAt
                 }
               }
               """,
               %{"echoId" => echo_id},
               admin
             )

    assert is_binary(revoked_at)

    assert [%{"code" => "flashback_wish_echo_invalid_transition"}] =
             post_graphql(
               """
               mutation CorrectRevoked($echoId: ID!, $content: String!) {
                 flashbackAdminCorrectWishEcho(echoId: $echoId, content: $content) {
                   id status
                 }
               }
               """,
               %{"echoId" => echo_id, "content" => "不能修改"},
               admin
             )["errors"]

    assert %{
             "data" => %{
               "flashbackAdminWishEchoes" => %{
                 "echoes" => [
                   %{
                     "id" => ^echo_id,
                     "status" => "revoked",
                     "publishedByUserId" => ^published_by_user_id
                   }
                 ]
               }
             }
           } = post_graphql(query, %{"wishId" => wish.id}, admin)
  end

  test "unlisted wishes are indistinguishable from missing wishes and invalid content is rejected" do
    admin = AccountsFixtures.platform_admin("wish-echo-invalid")
    wish = create_unlisted_wish()

    assert [%{"code" => "flashback_wish_not_found"}] =
             post_graphql(
               create_draft_mutation(),
               %{"wishId" => wish.id, "content" => "不能为未挂树愿望写回应"},
               admin
             )["errors"]

    listed_wish = create_listed_wish()

    for content <- ["   ", String.duplicate("回", 501)] do
      assert [%{"code" => "flashback_wish_echo_invalid_content"}] =
               post_graphql(
                 create_draft_mutation(),
                 %{"wishId" => listed_wish.id, "content" => content},
                 admin
               )["errors"]
    end
  end

  test "flashbackAdminListedWishes returns only visible listed wishes with echo counts (admin only)" do
    admin = AccountsFixtures.platform_admin("listed-wishes-admin")
    regular_user = AccountsFixtures.register_user("listed-wishes-viewer")

    wish = create_listed_wish()

    query = """
    query ListedWishes {
      flashbackAdminListedWishes {
        wishId
        content
        listedAt
        publishedEchoCount
        draftEchoCount
      }
    }
    """

    assert [%{"code" => "unauthorized"}] = post_graphql(query, %{})["errors"]

    assert [%{"code" => "forbidden"}] = post_graphql(query, %{}, regular_user)["errors"]

    assert %{
             "data" => %{
               "flashbackAdminListedWishes" => entries
             }
           } = post_graphql(query, %{}, admin)

    entry = Enum.find(entries, &(&1["wishId"] == wish.id))
    assert entry
    assert entry["content"] == "公开树愿望"
    assert entry["publishedEchoCount"] == 0
    assert entry["draftEchoCount"] == 0
    assert is_binary(entry["listedAt"])

    # 建草稿+发布后计数联动
    assert %{
             "data" => %{
               "flashbackAdminCreateWishEcho" => %{"status" => "draft"}
             }
           } =
             post_graphql(
               create_draft_mutation(),
               %{"wishId" => wish.id, "content" => "计数验证草稿"},
               admin
             )

    assert %{
             "data" => %{
               "flashbackAdminListedWishes" => entries2
             }
           } = post_graphql(query, %{}, admin)

    entry2 = Enum.find(entries2, &(&1["wishId"] == wish.id))
    assert entry2["draftEchoCount"] == 1
    assert entry2["publishedEchoCount"] == 0

    # 愿望下架后不再出现在队列（隐藏 = 无回响入口的前置条件）
    {:ok, _} =
      Cgc2046.Flashback.Reports.set_wish_hidden(wish.id, admin.id, true)

    assert %{
             "data" => %{
               "flashbackAdminListedWishes" => entries3
             }
           } = post_graphql(query, %{}, admin)

    refute Enum.find(entries3, &(&1["wishId"] == wish.id))
  end
end
