defmodule Cgc2046Web.GraphqlFlashbackNewWisherTest do
  use Cgc2046Web.ConnCase, async: false
  alias Cgc2046.{AccountsFixtures, Repo}
  alias Cgc2046.Flashback.{EventArchive, Person, Wishes, Wish}
  @moduletag :capture_log
  @create "mutation($text:String!, $visibility:String!, $requestId:ID){flashbackCreateWish(content:$text, visibility:$visibility, expectedCity:\"成都\", publicListingConsent:true, requestId:$requestId){id status}}"
  @mine "{flashbackMyWishes{quotaRemaining wishes{id content city visibility status}}}"
  defp request(session, query, variables \\ %{}) do
    conn =
      if session,
        do: put_req_cookie(build_conn(), "cgc_token", session.resp_cookies["cgc_token"].value),
        else: build_conn()

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{query: query, variables: variables})
    |> json_response(200)
  end

  defp login(user) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{
      query:
        ~s'mutation {signIn(login:"#{user.email}",password:"#{AccountsFixtures.password()}"){id}}'
    })
  end

  defp create(session, text, visibility \\ "public", key \\ nil),
    do: request(session, @create, %{text: text, visibility: visibility, requestId: key})

  test "无档案账号可写、本人回看、公开直达；不可越权删除；删除不退额度" do
    user = AccountsFixtures.register_user("new-wisher")
    session = login(user)

    assert %{"data" => %{"flashbackCreateWish" => %{"id" => id, "status" => "listed"}}} =
             create(session, "一起做第一个作品")

    wish = Ash.get!(Wish, id, authorize?: false)
    assert wish.person_id == nil
    assert wish.user_id == user.id
    assert Repo.aggregate(Person, :count) == 0

    assert %{
             "data" => %{
               "flashbackMyWishes" => %{"quotaRemaining" => 2, "wishes" => [%{"id" => ^id}]}
             }
           } = request(session, @mine)

    public = "{flashbackPublicWish(wishId:\"#{id}\"){id}}"
    assert %{"data" => %{"flashbackPublicWish" => %{"id" => ^id}}} = request(nil, public)
    other = login(AccountsFixtures.register_user("other-wisher"))
    delete = "mutation{flashbackDeleteWish(wishId:\"#{id}\")}"
    assert %{"errors" => [%{"code" => "flashback_forbidden_wish"}]} = request(other, delete)
    assert %{"data" => %{"flashbackDeleteWish" => true}} = request(session, delete)

    assert %{"data" => %{"flashbackMyWishes" => %{"quotaRemaining" => 2, "wishes" => []}}} =
             request(session, @mine)

    assert %{"data" => %{"flashbackPublicWish" => nil}} = request(nil, public)
  end

  test "游客不可写或读取本人面；私密和待审不泄露" do
    assert %{"errors" => [%{"code" => "flashback_auth_required"}]} = create(nil, "游客")
    assert %{"errors" => [%{"code" => "flashback_auth_required"}]} = request(nil, @mine)
    user = AccountsFixtures.register_user("private-wisher")
    session = login(user)

    assert %{"data" => %{"flashbackCreateWish" => %{"id" => private_id, "status" => "private"}}} =
             create(session, "只告诉平台", "private")

    Repo.query!("UPDATE users SET wishes_review_required_at=NOW() WHERE id=$1", [
      Repo.uuid!(user.id)
    ])

    assert %{
             "data" => %{
               "flashbackCreateWish" => %{"id" => pending_id, "status" => "pending_review"}
             }
           } = create(session, "等待审核")

    for id <- [private_id, pending_id],
        do:
          assert(
            %{"data" => %{"flashbackPublicWish" => nil}} =
              request(nil, "{flashbackPublicWish(wishId:\"#{id}\"){id}}")
          )

    assert %{"data" => %{"flashbackMyWishes" => %{"wishes" => mine}}} = request(session, @mine)
    assert Enum.sort(Enum.map(mine, & &1["status"])) == ["pending_review", "private"]
  end

  test "绑定前后合并额度，旧 person 写入不能绕过" do
    user = AccountsFixtures.register_user("bind-wisher")
    session = login(user)

    archive =
      EventArchive
      |> Ash.Changeset.for_create(:create, %{
        key: "wish-2a",
        name: "合成档案",
        city: "北京",
        occurred_on: ~D[2014-01-01]
      })
      |> Ash.create!(authorize?: false)

    person =
      Person
      |> Ash.Changeset.for_create(:create, %{
        archive_event_id: archive.id,
        full_name: "测试校友",
        city: "北京",
        participation: :attended
      })
      |> Ash.create!(authorize?: false)

    assert {:ok, _} = Wishes.create_wish(person.id, "历史愿望一", "private")
    assert {:ok, _} = Wishes.create_wish(person.id, "历史愿望二", "private")
    assert %{"data" => %{"flashbackCreateWish" => %{}}} = create(session, "新用户愿望")

    Repo.query!("UPDATE flashback_people SET user_id=$1 WHERE id=$2", [
      Repo.uuid!(user.id),
      Repo.uuid!(person.id)
    ])

    assert %{"data" => %{"flashbackMyWishes" => %{"quotaRemaining" => 0, "wishes" => mine}}} =
             request(session, @mine)

    assert length(mine) == 3

    assert %{"errors" => [%{"code" => "flashback_wish_quota_exceeded"}]} =
             create(session, "额度不能重置")

    assert {:error, %{code: "flashback_wish_quota_exceeded"}} =
             Wishes.create_wish(person.id, "旧入口也不能绕过", "public")
  end

  test "请求重放不重复占额度，同请求号不同正文拒绝" do
    session = login(AccountsFixtures.register_user("replay-wisher"))
    key = Ecto.UUID.generate()
    first = create(session, "网络重试愿望", "public", key)
    assert %{"data" => %{"flashbackCreateWish" => %{"id" => id}}} = first
    assert create(session, "网络重试愿望", "public", key) == first

    assert %{"errors" => [%{"code" => "flashback_wish_request_conflict"}]} =
             create(session, "不同正文", "public", key)

    assert %{
             "data" => %{
               "flashbackMyWishes" => %{"quotaRemaining" => 2, "wishes" => [%{"id" => ^id}]}
             }
           } = request(session, @mine)
  end
end
