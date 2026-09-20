defmodule Cgc2046Web.GraphqlFlashbackCardSharingTest do
  @moduledoc """
  #771 卡片分享链接 GraphQL 契约面：mutation `flashbackSetCardSharing`、
  query `flashbackSharedCard`（匿名）、`flashbackCapsule.me.cardSharing`。

  SDL 是 miniprogram codegen 的输入——本文件钉住字段名、选择集形状与
  匿名可读性（无 token / 无 slug 入参）。隐私面（雾面段空串、白名单键集）
  在 `test/cgc_2046/flashback/card_sharing_test.exs` 逐条钉住，此处只验
  传输层不额外泄露。

  RateLimit 是全局 ETS 表（同 graphql_flashback_test 先例）：
  async: false 防计数互相污染。
  """

  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.TokenCredential
  alias Cgc2046.AccountsFixtures
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Answer, Person, Token, Today}

  @moduletag :capture_log

  @card_selection """
  {
    displayName
    city
    appliedAt
    answers { questionKey segments { text fog len } }
    today { questionKey segments { text fog len } }
  }
  """

  defp post_graphql(query, variables \\ %{}) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query, "variables" => variables})
    |> json_response(200)
  end

  defp post_as_user(query, user) do
    mutation = """
    mutation { signIn(login: "#{user.email}", password: "#{AccountsFixtures.password()}") { id } }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => mutation})

    assert %{"data" => %{"signIn" => %{"id" => _}}} = json_response(conn, 200)
    token = conn.resp_cookies["cgc_token"].value

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end

  defp archive do
    Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: "2014-01-11-bj",
      name: "Rails Girls Beijing",
      city: "北京",
      occurred_on: ~D[2014-01-11]
    })
    |> Ash.create!(authorize?: false)
  end

  defp person(arch, attrs \\ %{}) do
    Person
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          archive_event_id: arch.id,
          full_name: "王小明",
          surname: "王",
          city: "北京",
          occupation_then: "学生",
          role: :learner,
          participation: :attended,
          phone: "13900000001",
          email: "card-share-graphql@example.com"
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp answer(person, key, text, fog_spans \\ []) do
    Answer
    |> Ash.Changeset.for_create(:create, %{
      person_id: person.id,
      question_key: key,
      raw_text: text,
      fog_spans: fog_spans
    })
    |> Ash.create!(authorize?: false)
  end

  defp today(person, attrs) do
    Today
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :person_id, person.id))
    |> Ash.create!(authorize?: false)
  end

  defp issue_token(person) do
    plain = "fb_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
    {:ok, hash} = TokenCredential.hash(plain)

    Token
    |> Ash.Changeset.for_create(:create, %{person_id: person.id, token_hash: hash})
    |> Ash.create!(authorize?: false)

    plain
  end

  defp set_card_sharing(plain, enabled) do
    post_graphql("""
    mutation { flashbackSetCardSharing(token: "#{plain}", enabled: #{enabled}) {
      enabled shareId: share_id preview #{@card_selection}
    } }
    """)
  end

  defp shared_card(share_id) do
    post_graphql("""
    query { flashbackSharedCard(shareId: "#{share_id}") #{@card_selection} }
    """)
  end

  describe "flashbackSetCardSharing（双入口 + 幂等）" do
    test "token 面：首开回 enabled/shareId/preview；关闭保留同号；重开复活" do
      arch = archive()
      person = person(arch)
      answer(person, "self_intro", "我在盛大做测试。喜欢周末骑行。", [%{"start" => 0, "len" => 6}])
      today(person, %{want: "想系统学 AI", need: "想找一位导师"})
      plain = issue_token(person)

      opened = set_card_sharing(plain, true)
      refute Map.has_key?(opened, "errors")

      payload = opened["data"]["flashbackSetCardSharing"]
      assert payload["enabled"] == true
      assert payload["shareId"] =~ ~r/^[0-9a-f]{48}$/
      # 预览：隐名 + 白名单节键（与公开面同一投影）
      assert payload["preview"]["displayName"] == "王**"
      assert Enum.map(payload["preview"]["answers"], & &1["questionKey"]) == ["self_intro"]

      assert Enum.map(payload["preview"]["today"], & &1["questionKey"]) ==
               ["today.want", "today.need"]

      share_id = payload["shareId"]

      # 关闭：enabled false，标识不动（preview 仍返回——本人面不受公开门限制）
      closed = set_card_sharing(plain, false)
      closed_payload = closed["data"]["flashbackSetCardSharing"]
      assert closed_payload["enabled"] == false
      assert closed_payload["shareId"] == share_id
      assert closed_payload["preview"]["displayName"] == "王**"

      # 重开：同号
      reopened = set_card_sharing(plain, true)
      assert reopened["data"]["flashbackSetCardSharing"]["shareId"] == share_id
    end

    test "登录账号面：绑定档案后 token 省略可用" do
      arch = archive()
      person = person(arch)
      answer(person, "os", "Ubuntu 14.04")
      user = AccountsFixtures.register_user("fb-card-share-session")

      person
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.update!(authorize?: false)

      res =
        post_as_user(
          """
          mutation { flashbackSetCardSharing(enabled: true) { enabled shareId: share_id
            preview { displayName } } }
          """,
          user
        )

      refute Map.has_key?(res, "errors")
      payload = res["data"]["flashbackSetCardSharing"]
      assert payload["enabled"] == true
      assert payload["shareId"] =~ ~r/^[0-9a-f]{48}$/
      assert payload["preview"]["displayName"] == "王**"
    end

    test "无 token 未登录 → flashback_auth_required；坏 token → token 面错误码" do
      res = post_graphql(~s|mutation { flashbackSetCardSharing(enabled: true) { enabled } }|)
      assert [%{"code" => "flashback_auth_required"}] = res["errors"]

      res =
        post_graphql(
          ~s|mutation { flashbackSetCardSharing(enabled: true, token: "fb_nope") { enabled } }|
        )

      assert [%{"code" => "flashback_token_not_found"}] = res["errors"]
    end
  end

  describe "flashbackSharedCard（匿名可读，无 token / 无 slug）" do
    test "开启后匿名可解析；白名单节键与段形状（雾段空串）" do
      arch = archive()
      person = person(arch)
      answer(person, "self_intro", "我在盛大做测试。喜欢周末骑行。", [%{"start" => 0, "len" => 6}])
      answer(person, "funny_thing", "把生产库当测试库。")
      answer(person, "os", "Ubuntu 14.04")
      answer(person, "social_media", "weibo.com/wangxiaoming")

      today(person, %{
        now_status: "还在写代码",
        want: "想系统学 AI",
        need: "想找一位导师",
        say: "十周年快乐！"
      })

      plain = issue_token(person)
      share_id = set_card_sharing(plain, true)["data"]["flashbackSetCardSharing"]["shareId"]

      res = shared_card(share_id)
      refute Map.has_key?(res, "errors")

      card = res["data"]["flashbackSharedCard"]
      assert card["displayName"] == "王**"
      assert card["city"] == "北京"
      assert Enum.map(card["answers"], & &1["questionKey"]) == ["self_intro", "funny_thing", "os"]

      assert Enum.map(card["today"], & &1["questionKey"]) == [
               "today.now",
               "today.want",
               "today.need",
               "today.say"
             ]

      # 段形状：雾段 text 空串、len 保档位；明文段原样；段序为原文顺序
      intro = Enum.find(card["answers"], &(&1["questionKey"] == "self_intro"))

      assert [
               %{"text" => "", "fog" => true, "len" => 6},
               %{"text" => "试。喜欢周末骑行。", "fog" => false}
             ] =
               intro["segments"]

      # 敏感列与不在白名单的答案键零出现（响应体整体扫描）
      body = inspect(res)
      refute body =~ "13900000001"
      refute body =~ "card-share-graphql@example.com"
      refute body =~ "weibo.com"
      refute body =~ "social_media"
      refute body =~ "我在盛大做测试"
      refute body =~ "fog_spans"
    end

    test "未知 id / 已关闭 / 已删除 → null（不区分原因）" do
      arch = archive()
      person = person(arch)
      answer(person, "os", "Ubuntu 14.04")
      plain = issue_token(person)

      unknown = shared_card(String.duplicate("0", 48))
      assert unknown["data"]["flashbackSharedCard"] == nil

      share_id = set_card_sharing(plain, true)["data"]["flashbackSetCardSharing"]["shareId"]
      assert shared_card(share_id)["data"]["flashbackSharedCard"] != nil

      set_card_sharing(plain, false)
      assert shared_card(share_id)["data"]["flashbackSharedCard"] == nil

      set_card_sharing(plain, true)

      Cgc2046.Flashback.Deletion.delete(%{person: person}, "DELETE")
      assert shared_card(share_id)["data"]["flashbackSharedCard"] == nil
    end

    test "匿名不可变更：访客拿 shareId 无法改开关（无此 mutation 入参面）" do
      arch = archive()
      person = person(arch)
      answer(person, "os", "Ubuntu 14.04")
      plain = issue_token(person)
      share_id = set_card_sharing(plain, true)["data"]["flashbackSetCardSharing"]["shareId"]

      # shareId 不是任何写面入参：试图当 token 用 → token 面错误码（不改状态）
      res = set_card_sharing(share_id, false)
      assert [%{"code" => "flashback_token_not_found"}] = res["errors"]
      assert shared_card(share_id)["data"]["flashbackSharedCard"] != nil

      # 匿名调 mutation → auth_required，状态不变
      anon = post_graphql(~s|mutation { flashbackSetCardSharing(enabled: false) { enabled } }|)
      assert [%{"code" => "flashback_auth_required"}] = anon["errors"]
      assert shared_card(share_id)["data"]["flashbackSharedCard"] != nil
    end
  end

  describe "flashbackCapsule.me.cardSharing" do
    test "未开启：enabled false / shareId null / preview 恒有" do
      arch = archive()
      person = person(arch)
      answer(person, "self_intro", "我在盛大做测试。")
      plain = issue_token(person)

      res =
        post_graphql("""
        query { flashbackCapsule(token: "#{plain}") { me { cardSharing: card_sharing {
          enabled shareId: share_id preview { displayName } } } } }
        """)

      refute Map.has_key?(res, "errors")
      sharing = res["data"]["flashbackCapsule"]["me"]["cardSharing"]
      assert sharing["enabled"] == false
      assert sharing["shareId"] == nil
      assert sharing["preview"]["displayName"] == "王**"
    end

    test "开启后：capsule 与公开面同标识；关闭后 capsule 仍可见标识" do
      arch = archive()
      person = person(arch)
      answer(person, "self_intro", "我在盛大做测试。")
      plain = issue_token(person)

      share_id = set_card_sharing(plain, true)["data"]["flashbackSetCardSharing"]["shareId"]

      res =
        post_graphql("""
        query { flashbackCapsule(token: "#{plain}") { me { cardSharing: card_sharing {
          enabled shareId: share_id } } } }
        """)

      assert res["data"]["flashbackCapsule"]["me"]["cardSharing"]["enabled"] == true
      assert res["data"]["flashbackCapsule"]["me"]["cardSharing"]["shareId"] == share_id

      set_card_sharing(plain, false)

      res =
        post_graphql("""
        query { flashbackCapsule(token: "#{plain}") { me { cardSharing: card_sharing {
          enabled shareId: share_id } } } }
        """)

      assert res["data"]["flashbackCapsule"]["me"]["cardSharing"]["enabled"] == false
      assert res["data"]["flashbackCapsule"]["me"]["cardSharing"]["shareId"] == share_id
    end
  end

  describe "SDL 冻结（miniprogram codegen 输入）" do
    test "分享相关字段与类型都在 SDL 中声明" do
      sdl = File.read!("priv/graphql/schema.graphql")

      assert sdl =~ "flashbackSetCardSharing("
      assert sdl =~ "flashbackSharedCard("
      assert sdl =~ "type FlashbackCardSharing {"
      assert sdl =~ "type FlashbackSharedCard {"
      assert sdl =~ "type FlashbackSharedCardSection {"
      assert sdl =~ "type FlashbackSharedCardSegment {"
      assert sdl =~ "cardSharing: FlashbackCardSharing!"
      # 写面无 token / 无 slug 旁路：访客路由不带 token 参数
      refute sdl =~ "flashbackSharedCard(shareId: String!, token"
    end
  end
end
