defmodule Cgc2046Web.GraphqlFlashbackLikesTest do
  @moduledoc """
  R35-R38 GraphQL 契约面：金句墙点赞（公开）/ 点赞数回显 / 作者侧 quoteStats /
  管理端下线（PlatformAdmin gate）。

  SDL 是 miniprogram codegen 的输入——本文件同时钉住字段名与错误码。
  """

  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.TokenCredential
  alias Cgc2046.AccountsFixtures
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Answer, Person, QuoteLicense, Token}

  @moduletag :capture_log

  @quotes_query """
  query($voterKey: String) {
    flashbackPublicQuotes(voterKey: $voterKey) {
      text attribution level publicSlug quoteId city year likeCount likedByViewer
    }
  }
  """

  defp post_graphql(query, variables \\ %{}, user \\ nil) do
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
    mutation = """
    mutation { signIn(login: "#{user.email}", password: "#{AccountsFixtures.password()}") { id } }
    """

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => mutation})
    |> Map.fetch!(:resp_cookies)
    |> Map.fetch!("cgc_token")
    |> Map.fetch!(:value)
  end

  defp archive do
    Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: "2014-01-11-bj",
      name: "Rails Girls Beijing",
      city: "北京",
      occurred_on: ~D[2014-01-11],
      applied_count: 344,
      attended_count: 102
    })
    |> Ash.create!(authorize?: false)
  end

  defp wall_person(arch, attrs) do
    person =
      Person
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(
          %{
            archive_event_id: arch.id,
            full_name: "王晓雨",
            surname: "王",
            city: "北京",
            occupation_then: "学生",
            role: :learner,
            participation: :attended,
            phone: "13900000009",
            email: "likes-graphql@example.com"
          },
          attrs
        )
      )
      |> Ash.create!(authorize?: false)

    Answer
    |> Ash.Changeset.for_create(:create, %{
      person_id: person.id,
      question_key: "self_intro",
      raw_text: "我想亲眼看看是不是。"
    })
    |> Ash.create!(authorize?: false)

    license =
      QuoteLicense
      |> Ash.Changeset.for_create(:create, %{
        person_id: person.id,
        level: :anonymous,
        chosen_quote_spans: [%{"question_key" => "self_intro", "start" => 0, "len" => 5}]
      })
      |> Ash.create!(authorize?: false)

    # R37：测试夹具直建行（绕过 Tokens.set_quote_license 的同步路径）——
    # 显式同步 Quote 行，与生产写面同终态。
    {:ok, [quote | _]} = Cgc2046.Flashback.Quotes.sync_for_license(license)
    {person, quote}
  end

  defp token_for(person) do
    plain = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    {:ok, hash} = TokenCredential.hash(plain)

    Token
    |> Ash.Changeset.for_create(:create, %{person_id: person.id, token_hash: hash})
    |> Ash.create!(authorize?: false)

    plain
  end

  describe "金句墙城市过滤" do
    test "城市在热门 60 条截断之前过滤；撤回内容不出现" do
      arch = archive()
      {_person, chengdu} = wall_person(arch, %{city: "成都", email: "city-cd@example.com"})

      for index <- 1..61 do
        wall_person(arch, %{city: "北京", email: "city-bj-#{index}@example.com"})
      end

      query = """
      query($city: String) { flashbackPublicQuotes(city: $city) { quoteId city text } }
      """

      assert %{"data" => %{"flashbackPublicQuotes" => all}} = post_graphql(query)
      assert length(all) == 60
      refute Enum.any?(all, &(&1["quoteId"] == chengdu.id))

      assert %{"data" => %{"flashbackPublicQuotes" => [only]}} =
               post_graphql(query, %{"city" => "成都"})

      assert only["quoteId"] == chengdu.id

      cities_query = "{ flashbackVoiceCities { name pinyin lngLat } }"
      assert %{"data" => %{"flashbackVoiceCities" => cities}} = post_graphql(cities_query)
      assert Enum.map(cities, & &1["name"]) == ["北京", "成都"]
      assert Enum.all?(cities, &(length(&1["lngLat"]) == 2))

      assert %{"data" => %{"flashbackPublicQuotes" => []}} =
               post_graphql(query, %{"city" => "没有内容的城市"})

      Cgc2046.Repo.query!("UPDATE flashback_quotes SET hidden_at = NOW() WHERE id = $1", [
        Ecto.UUID.dump!(chengdu.id)
      ])

      assert %{"data" => %{"flashbackPublicQuotes" => []}} =
               post_graphql(query, %{"city" => "成都"})

      assert %{"data" => %{"flashbackVoiceCities" => [%{"name" => "北京"}]}} =
               post_graphql(cities_query)
    end

    test "城市目录排除未公开授权和已删除档案" do
      arch = archive()
      {private_person, _} = wall_person(arch, %{city: "杭州"})
      {deleted_person, _} = wall_person(arch, %{city: "上海"})
      {hidden_person, _} = wall_person(arch, %{city: "广州"})

      Cgc2046.Repo.query!(
        "UPDATE flashback_quote_licenses SET level = 'off' WHERE person_id = $1",
        [Ecto.UUID.dump!(private_person.id)]
      )

      Cgc2046.Repo.query!("UPDATE flashback_people SET deleted_at = NOW() WHERE id = $1", [
        Ecto.UUID.dump!(deleted_person.id)
      ])

      Cgc2046.Repo.query!(
        "UPDATE flashback_quote_licenses SET hidden_at = NOW() WHERE person_id = $1",
        [Ecto.UUID.dump!(hidden_person.id)]
      )

      assert %{"data" => %{"flashbackVoiceCities" => []}} =
               post_graphql("{ flashbackVoiceCities { name } }")
    end
  end

  describe "flashbackLikeQuote（R36/R37 公开面）" do
    test "点赞幂等 + 返回实时计数 + 取消；voterKey 非法 fail-closed" do
      {_person, quote} = wall_person(archive(), %{email: "like-mutation@example.com"})

      like = fn voter, liked ->
        """
        mutation {
          flashbackLikeQuote(quoteId: "#{quote.id}", voterKey: "#{voter}", liked: #{liked}) {
            likeCount
          }
        }
        """
      end

      assert %{"data" => %{"flashbackLikeQuote" => %{"likeCount" => 1}}} =
               post_graphql(like.("a:device-gql", true))

      # 幂等：重复点赞不重复计数
      assert %{"data" => %{"flashbackLikeQuote" => %{"likeCount" => 1}}} =
               post_graphql(like.("a:device-gql", true))

      assert %{"data" => %{"flashbackLikeQuote" => %{"likeCount" => 2}}} =
               post_graphql(like.("u:user-gql", true))

      assert %{"data" => %{"flashbackLikeQuote" => %{"likeCount" => 1}}} =
               post_graphql(like.("a:device-gql", false))

      # 非法 voter_key → 业务码（不是 500）
      res =
        post_graphql("""
        mutation {
          flashbackLikeQuote(quoteId: "#{quote.id}", voterKey: "nope", liked: true) { likeCount }
        }
        """)

      assert [%{"code" => "flashback_invalid_voter_key"}] = res["errors"]
    end
  end

  describe "flashbackPublicQuotes（R36/R37 点赞回显与排序）" do
    test "quoteId/likeCount/likedByViewer 三字段 + 点击排序生效" do
      arch = archive()

      {_alice, alice_quote} =
        wall_person(arch, %{email: "q-a@example.com", full_name: "王晓雨", surname: "王"})

      {_bob, bob_quote} =
        wall_person(arch, %{email: "q-b@example.com", full_name: "李雷", surname: "李"})

      post_graphql("""
      mutation { flashbackLikeQuote(quoteId: "#{alice_quote.id}", voterKey: "a:v1", liked: true) { likeCount } }
      """)

      post_graphql("""
      mutation { flashbackLikeQuote(quoteId: "#{alice_quote.id}", voterKey: "a:v2", liked: true) { likeCount } }
      """)

      post_graphql("""
      mutation { flashbackLikeQuote(quoteId: "#{bob_quote.id}", voterKey: "a:v1", liked: true) { likeCount } }
      """)

      res = post_graphql(@quotes_query, %{"voterKey" => "a:v1"})
      quotes = res["data"]["flashbackPublicQuotes"]

      assert [first, second] = Enum.take(quotes, 2)
      assert first["quoteId"] == alice_quote.id
      assert first["likeCount"] == 2
      assert first["likedByViewer"] == true
      assert first["text"] == "我想亲眼看"
      assert first["city"] == "北京"
      assert first["year"] == 2014
      assert second["quoteId"] == bob_quote.id
      assert second["likeCount"] == 1
      assert second["likedByViewer"] == true

      # 不传 voterKey：likedByViewer 恒 false（匿名只读）
      anonymous = post_graphql(@quotes_query)["data"]["flashbackPublicQuotes"]
      assert Enum.all?(anonymous, &(&1["likedByViewer"] == false))
    end

    test "flashbackRandomQuotes / flashbackPublicQuote（R35/R37 读面）" do
      arch = archive()
      {_a, quote} = wall_person(arch, %{email: "rq@example.com"})

      random =
        post_graphql("""
        query { flashbackRandomQuotes(limit: 3) { quoteId text } }
        """)

      assert [%{"quoteId" => _, "text" => "我想亲眼看"}] = random["data"]["flashbackRandomQuotes"]

      direct =
        post_graphql("""
        query { flashbackPublicQuote(quoteId: "#{quote.id}") { quoteId text } }
        """)

      assert direct["data"]["flashbackPublicQuote"]["quoteId"] == quote.id

      # 不存在/非法 id → null（不泄露存在性）
      missing =
        post_graphql("""
        query { flashbackPublicQuote(quoteId: "#{Ecto.UUID.generate()}") { quoteId } }
        """)

      assert missing["data"]["flashbackPublicQuote"] == nil
    end
  end

  describe "作者侧 quoteStats（R36 回访面）" do
    test "capsule.me.quoteStats.likeCount 随点赞变化" do
      {person, quote} = wall_person(archive(), %{email: "stats-gql@example.com"})
      token = token_for(person)

      post_graphql("""
      mutation { flashbackLikeQuote(quoteId: "#{quote.id}", voterKey: "a:s1", liked: true) { likeCount } }
      """)

      capsule = """
      query { flashbackCapsule(token: "#{token}") { me { quoteStats { likeCount } quoteLevel } } }
      """

      assert %{
               "data" => %{
                 "flashbackCapsule" => %{
                   "me" => %{"quoteStats" => %{"likeCount" => 1}, "quoteLevel" => "anonymous"}
                 }
               }
             } = post_graphql(capsule)
    end
  end

  describe "flashbackAdminSetQuoteHidden（R38 平台边界）" do
    test "非管理员被拒；管理员下线后金句墙与实名档案页同时消失" do
      {person, quote} = wall_person(archive(), %{email: "hidden-gql@example.com"})

      published =
        person
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:public_slug, "wang-xiaoyu-gql")
        |> Ash.Changeset.force_change_attribute(:public_slug_published_at, DateTime.utc_now())
        |> Ash.update!(authorize?: false)

      hide = """
      mutation { flashbackAdminSetQuoteHidden(personId: "#{published.id}", hidden: true) { personId hidden } }
      """

      # 未登录 → unauthorized（with_admin gate）
      assert [%{"code" => "unauthorized"}] = post_graphql(hide)["errors"]

      # 普通用户（已登录但非 admin）→ forbidden（与未登录的 unauthorized 区分）
      plain = AccountsFixtures.register_user("flashback-hidden-plain")
      assert [%{"code" => "forbidden"}] = post_graphql(hide, %{}, plain)["errors"]

      # 管理员 → 下线
      admin = AccountsFixtures.platform_admin("flashback-hidden-admin")

      assert %{"data" => %{"flashbackAdminSetQuoteHidden" => %{"hidden" => true}}} =
               post_graphql(hide, %{}, admin)

      quotes = post_graphql(@quotes_query)["data"]["flashbackPublicQuotes"]
      refute Enum.any?(quotes, &(&1["quoteId"] == quote.id))

      profile =
        post_graphql("query { flashbackPublicProfile(slug: \"wang-xiaoyu-gql\") { fullName } }")

      assert profile["data"]["flashbackPublicProfile"] == nil

      # 恢复
      assert %{"data" => %{"flashbackAdminSetQuoteHidden" => %{"hidden" => false}}} =
               post_graphql(String.replace(hide, "hidden: true", "hidden: false"), %{}, admin)

      quotes = post_graphql(@quotes_query)["data"]["flashbackPublicQuotes"]
      assert Enum.any?(quotes, &(&1["quoteId"] == quote.id))
    end
  end
end
