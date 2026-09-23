defmodule Cgc2046Web.GraphqlFlashbackPublicWishViewerTest do
  @moduledoc """
  wish2 review HS-3 双键读面端到端守卫：`flashbackPublicWishes` /
  `flashbackPublicWish` 的 resolver 在登录态强制 `u:<user_id>` 与入参 `a:`
  设备键**双键合并**回显（期待 mutation 登录态按 u: 记账 → 带 a: 键查询仍
  回显 true——刷新不漂移）；未登录维持入参单键。
  """
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.WishExpectations
  alias Cgc2046.Flashback.Wishes

  @moduletag :capture_log

  defp post_graphql(conn, query, variables \\ %{}) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query, "variables" => variables})
    |> json_response(200)
  end

  defp archive do
    Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: "2014-01-11-viewer-#{System.unique_integer([:positive])}",
      name: "Rails Girls Beijing",
      city: "北京",
      occurred_on: ~D[2014-01-11]
    })
    |> Ash.create!(authorize?: false)
  end

  defp person(arch, attrs \\ %{}) do
    Flashback.Person
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          archive_event_id: arch.id,
          full_name: "王小明",
          surname: "王",
          city: "北京",
          participation: :attended
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp listed_wish(person, content) do
    {:ok, wish} =
      Wishes.create_wish(person.id, content, "public",
        public_listing_consent: true,
        signature_choice: :anonymous
      )

    wish
  end

  # 登录拿 httpOnly cookie（返回 conn 本身——resp_cookies 要给 recycle_cookie）
  defp sign_in_conn(conn, user) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/api/graphql",
      %{
        "query" =>
          ~s'mutation { signIn(login: "#{user.email}", password: "#{Cgc2046.AccountsFixtures.password()}") { id } }'
      }
    )
  end

  defp wishes_query do
    """
    query FlashbackPublicWishes($voterKey: String) {
      flashbackPublicWishes(voterKey: $voterKey) {
        id
        expectedByViewer
        endorsedByViewer
      }
    }
    """
  end

  test "登录用户带 a: 设备键查询：u: 记账的期待态回显 true（双键合并）" do
    arch = archive()
    author = person(arch)
    wish = listed_wish(author, "双键回显愿望")

    user = Cgc2046.AccountsFixtures.register_user("viewer-hs3")
    login_conn = sign_in_conn(build_conn(), user)

    # 登录态期待（cookie 复用 → resolver actor 强制 u:<uid> 记账）。
    # 每次 post 用 fresh conn + cookie header（Plug conn 一次性）。
    authed_expect = recycle_cookie(build_conn(), login_conn)

    post_graphql(
      authed_expect,
      """
      mutation FlashbackExpectWish($wishId: ID!, $expected: Boolean!) {
        flashbackExpectWish(wishId: $wishId, expected: $expected) {
          expectationCount
          expectedByMe
        }
      }
      """,
      %{"wishId" => wish.id, "expected" => true}
    )

    # 同一登录会话 + a: 设备键查询（前端 wishes-wall 恒传设备键的真实路径）
    authed_conn = recycle_cookie(build_conn(), login_conn)

    result = post_graphql(authed_conn, wishes_query(), %{"voterKey" => "a:device-1"})

    rows = result["data"]["flashbackPublicWishes"]
    row = Enum.find(rows, &(&1["id"] == wish.id))

    assert row["expectedByViewer"] == true,
           "登录态 u: 记账的期待必须经双键合并回显——否则刷新即漂移（HS-3）"
  end

  test "未登录带 a: 键查询不受双键合并影响（匿名记账单键回显）" do
    arch = archive()
    author = person(arch)
    wish = listed_wish(author, "匿名回显愿望")

    anon_key = "a:anon-hs3"
    {:ok, _} = WishExpectations.set_expectation(wish.id, true, anon_voter_key: anon_key)

    result = post_graphql(build_conn(), wishes_query(), %{"voterKey" => anon_key})
    row = Enum.find(result["data"]["flashbackPublicWishes"], &(&1["id"] == wish.id))
    assert row["expectedByViewer"] == true

    # 不同 a: 键 → false（单键精确匹配，不因双键放宽而误回显）
    other = post_graphql(build_conn(), wishes_query(), %{"voterKey" => "a:other"})
    row_other = Enum.find(other["data"]["flashbackPublicWishes"], &(&1["id"] == wish.id))
    assert row_other["expectedByViewer"] == false
  end

  test "公开树完整字段矩阵经 HTTP 序列化不 500（E2E P1：naive datetime 装箱）" do
    arch = archive()
    author = person(arch)
    wish = listed_wish(author, "时间字段愿望")

    result =
      post_graphql(
        build_conn(),
        """
        query {
          flashbackPublicWishes {
            id
            content
            city
            signature
            expectationCount
            endorsementCount
            contributionDistribution
            expectedByViewer
            endorsedByViewer
            listedAt
            insertedAt
          }
          flashbackPublicWish(wishId: "#{wish.id}") {
            id
            listedAt
            insertedAt
          }
        }
        """
      )

    # 500 / Absinthe datetime MatchError 会落 errors 且无 data——此处必须
    # 两字段真实序列化为 ISO 字符串
    assert result["errors"] == nil
    rows = result["data"]["flashbackPublicWishes"]
    row = Enum.find(rows, &(&1["id"] == wish.id))
    assert row["listedAt"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
    assert row["insertedAt"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
    assert result["data"]["flashbackPublicWish"]["listedAt"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
  end

  test "未登录附议/取消附议 → flashback_auth_required（plan U3 契约）" do
    arch = archive()
    author = person(arch)
    wish = listed_wish(author, "登录门槛愿望")

    endorse =
      post_graphql(
        build_conn(),
        """
        mutation { flashbackEndorseWish(wishId: "#{wish.id}") { endorsementCount } }
        """
      )

    assert [%{"code" => "flashback_auth_required"}] = endorse["errors"]

    cancel =
      post_graphql(
        build_conn(),
        """
        mutation { flashbackCancelEndorseWish(wishId: "#{wish.id}") { endorsementCount } }
        """
      )

    assert [%{"code" => "flashback_auth_required"}] = cancel["errors"]
  end

  test "城市过滤归一（plans/006）：全称「成都市」命中「成都」愿望；未知城市宽容空" do
    arch = archive()
    # listed_wish 不传 expected_city → wish.city 取 person 名册城市归一值
    cd_author = person(arch, %{city: "成都", full_name: "李小红", surname: "李"})
    cd_wish = listed_wish(cd_author, "成都归一愿望")
    bj_author = person(arch, %{full_name: "张小明", surname: "张"})
    _bj_wish = listed_wish(bj_author, "北京对照愿望")

    # wishes_query/0 不带 city 参数——本用例内联带 $city 变量的查询
    query = """
    query CityFilter($city: String) {
      flashbackPublicWishes(city: $city) {
        id
      }
    }
    """

    # 全称「成都市」→ resolver 归一为「成都」命中（schema 与表单同源 KTD11）
    %{"data" => %{"flashbackPublicWishes" => wishes}} =
      post_graphql(build_conn(), query, %{"city" => "成都市"})

    ids = Enum.map(wishes, & &1["id"])
    assert cd_wish.id in ids
    assert length(wishes) == 1

    # 未识别城市原样直传 → 宽容空（读面不报错）
    %{"data" => %{"flashbackPublicWishes" => none}} =
      post_graphql(build_conn(), query, %{"city" => "不存在的城市"})

    assert none == []
  end

  defp recycle_cookie(conn, resp_conn) do
    case resp_conn.resp_cookies["cgc_token"] do
      %{value: value} ->
        put_req_header(conn, "cookie", "cgc_token=#{value}")

      _ ->
        conn
    end
  end
end
