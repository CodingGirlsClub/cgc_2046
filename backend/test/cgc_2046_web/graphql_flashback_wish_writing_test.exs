defmodule Cgc2046Web.GraphqlFlashbackWishWritingTest do
  @moduledoc """
  wish2 U8：mutation `flashbackCreateWish` 三新参（signatureChoice /
  expectedCity / publicListingConsent）的 GraphQL 契约面。

  语义（listed_at 授权 / 签名快照 / 城市归一）在
  `test/cgc_2046/flashback/wishes_test.exs` 的 U1 KTD1 describe 逐条钉住；
  本文件只验传输层：args 透传到 context opts、错误信封（city_unknown 带
  candidates）不落到 database_error 兜底。

  RateLimit 是全局 ETS 表（同 graphql_flashback_test 先例）：
  async: false 防计数互相污染。
  """

  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.TokenCredential
  alias Cgc2046.AccountsFixtures
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Person, Token, Wish}
  alias Cgc2046.Repo
  require Ash.Query

  @moduletag :capture_log

  defp post_graphql(query, variables \\ %{}) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query, "variables" => variables})
    |> json_response(200)
  end

  defp archive do
    Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: "2014-01-11-bj-wish8",
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
          gender: "female",
          participation: "attended",
          applied_at: ~D[2014-01-01],
          email: "wish-writing-u8@example.com"
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp token_for(person) do
    plain = "fb_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
    {:ok, hash} = TokenCredential.hash(plain)

    Token
    |> Ash.Changeset.for_create(:create, %{person_id: person.id, token_hash: hash})
    |> Ash.create!(authorize?: false)

    plain
  end

  defp create_wish_mutation do
    """
    mutation CreateWish($token: String, $content: String!, $visibility: String!,
                         $signatureChoice: String, $expectedCity: String,
                         $publicListingConsent: Boolean) {
      flashbackCreateWish(token: $token, content: $content, visibility: $visibility,
                          signatureChoice: $signatureChoice, expectedCity: $expectedCity,
                          publicListingConsent: $publicListingConsent) {
        endorsementCount
        endorsedByMe
      }
    }
    """
  end

  defp wish_by_content(content) do
    Wish
    |> Ash.Query.filter(content == ^content)
    |> Ash.read_one!(authorize?: false, load: [])
  end

  @tag :capture_log
  test "publicListingConsent=true + public → listed_at 写入（挂树）；署名/城市快照透传" do
    arch = archive()
    person = person(arch)
    token = token_for(person)

    assert %{"data" => %{"flashbackCreateWish" => %{"endorsementCount" => 0}}} =
             post_graphql(create_wish_mutation(), %{
               "token" => token,
               "content" => "一起办一场十周年重聚",
               "visibility" => "public",
               "signatureChoice" => "display_name",
               "expectedCity" => "成都",
               "publicListingConsent" => true
             })

    wish = wish_by_content("一起办一场十周年重聚")
    assert %DateTime{} = wish.listed_at
    # KTD1：display_name = 实名展示快照（person.full_name）
    assert wish.signature == "王小明"
    # KTD11：显式入参强制归一（成都市 → 成都）
    assert wish.city == "成都"
  end

  test "缺省新参（旧客户端形状）→ 与 U1 默认 opts 等价：listed_at NULL + 遮罩署名" do
    arch = archive()
    person = person(arch)
    token = token_for(person)

    assert %{"data" => %{"flashbackCreateWish" => _}} =
             post_graphql(create_wish_mutation(), %{
               "token" => token,
               "content" => "旧客户端愿望",
               "visibility" => "public"
             })

    wish = wish_by_content("旧客户端愿望")
    assert wish.listed_at == nil
    assert wish.signature == "王**"
    assert wish.city == "北京"
  end

  test "signatureChoice 非法值宽容降级 anonymous（不拒单）" do
    arch = archive()
    person = person(arch)
    token = token_for(person)

    assert %{"data" => %{"flashbackCreateWish" => _}} =
             post_graphql(create_wish_mutation(), %{
               "token" => token,
               "content" => "拼写错误的署名档",
               "visibility" => "private",
               "signatureChoice" => "legal_name"
             })

    assert wish_by_content("拼写错误的署名档").signature == "王**"
  end

  test "expectedCity 名单外（无近似候选）→ flashback_wish_city_unknown 顶层 code，不编造候选" do
    arch = archive()
    person = person(arch)
    token = token_for(person)

    result =
      post_graphql(create_wish_mutation(), %{
        "token" => token,
        "content" => "去一个不存在的城市办一场",
        "visibility" => "public",
        "expectedCity" => "亚特兰蒂斯"
      })

    # 顶层 code（keyword error 序列化路径，同 quota_exceeded 先例）；
    # 无近似候选的输入（亚特兰蒂斯）不带 candidates 字段
    assert [
             %{
               "code" => "flashback_wish_city_unknown",
               "message" => "没认出这是哪个城市，换个写法试试（如：上海、成都）"
             } = first
           ] = result["errors"]

    refute Map.has_key?(first, "candidates")
    assert wish_by_content("去一个不存在的城市办一场") == nil
  end

  test "expectedCity 前缀可命中（「成」→ 成都…）→ candidates（≤3）顶层透传" do
    arch = archive()
    person = person(arch)
    token = token_for(person)

    result =
      post_graphql(create_wish_mutation(), %{
        "token" => token,
        "content" => "前缀候选愿望",
        "visibility" => "public",
        "expectedCity" => "成"
      })

    [entry] = result["errors"]
    assert entry["code"] == "flashback_wish_city_unknown"
    assert is_list(entry["candidates"]) and entry["candidates"] != []
  end

  defp create_wish_with_status(token, content, extra \\ %{}) do
    post_graphql(
      """
      mutation CreateWish($token: String, $content: String!, $visibility: String!,
                           $publicListingConsent: Boolean) {
        flashbackCreateWish(token: $token, content: $content, visibility: $visibility,
                            publicListingConsent: $publicListingConsent) {
          endorsementCount
          endorsedByMe
          status
        }
      }
      """,
      Map.merge(
        %{
          "token" => token,
          "content" => content,
          "visibility" => "public",
          "publicListingConsent" => true
        },
        extra
      )
    )
  end

  test "三态 status：正常作者 public+consent → listed" do
    arch = archive()
    person = person(arch)
    token = token_for(person)

    assert %{"data" => %{"flashbackCreateWish" => %{"status" => "listed"}}} =
             create_wish_with_status(token, "正常挂树")

    assert %DateTime{} = wish_by_content("正常挂树").listed_at
  end

  test "三态 status：private → private" do
    arch = archive()
    person = person(arch)
    token = token_for(person)

    assert %{"data" => %{"flashbackCreateWish" => %{"status" => "private"}}} =
             create_wish_with_status(token, "说给主办方听", %{"visibility" => "private"})
  end

  test "三态 status：信用降级作者（wishes_review_required_at 置位）public+consent → pending_review 不挂树" do
    arch = archive()
    user = AccountsFixtures.register_user("wish-u8-review")

    person =
      Person
      |> Ash.Changeset.for_create(
        :create,
        %{
          archive_event_id: arch.id,
          full_name: "信用作者",
          surname: "信",
          city: "北京",
          occupation_then: "学生",
          gender: "female",
          participation: "attended",
          applied_at: ~D[2014-01-01],
          email: "wish-u8-review-bound@example.com"
        }
      )
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.create!(authorize?: false)

    # 信用置位（G1 字段——U5 reports 联动的手置等价形态）
    {:ok, _} =
      Repo.query(
        "UPDATE users SET wishes_review_required_at = NOW() WHERE id = $1",
        [Repo.uuid!(user.id)]
      )

    token = token_for(person)

    assert %{"data" => %{"flashbackCreateWish" => %{"status" => "pending_review"}}} =
             create_wish_with_status(token, "信用待审愿望")

    wish = wish_by_content("信用待审愿望")
    assert wish.listed_at == nil
    assert %DateTime{} = wish.hidden_at
    # 不进公开树（四条件过滤）；admin 放行（清 hidden_at）后才挂
    refute Enum.any?(Cgc2046.Flashback.Wishes.list_public_listed(), &(&1.id == wish.id))
  end
end
