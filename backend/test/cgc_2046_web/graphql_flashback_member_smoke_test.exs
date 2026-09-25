defmodule Cgc2046Web.GraphqlFlashbackMemberSmokeTest do
  @moduledoc """
  #844 测试 PR（PR 2 flashback 搬迁前的钉测）：`flashback_identity`
  （token 入口）5 个 mutation——flashbackAddWishComment /
  flashbackAdjustTodayFog / flashbackDeleteWish /
  flashbackDeleteWishComment / flashbackRedeem。走真实
  POST /api/graphql 入口，钉住当前行为。

  变异验证（随附记录）：M2：`flashback_call/1` 改为恒返回错误 →
  本文件全部测试红（mutation 本体与 fixture 的 flashbackCreateWish
  均经该入口）。红后还原复跑全绿。M4（跳过写、保留成功返回）：
  add_comment 不落库 → 留言落库断言红（delete_comment 的 fixture
  同走该函数一并红）；soft_delete_wish / soft_delete_comment 跳过
  更新 → 两条软删落库断言各自红；adjust_today_fog 更新体不带
  fog_spans → 雾面持久化断言红。
  """

  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.TokenCredential
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Person, Token, Wish, WishComment}

  require Ash.Query

  @moduletag :capture_log

  # 各文件自带 fixture 是现有惯例，抽成共享模块不在 #844 范围。
  defp post_graphql(query, variables) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query, "variables" => variables})
    |> json_response(200)
  end

  defp archive do
    Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: "fb-smoke-member-#{System.unique_integer([:positive])}",
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
          participation: :attended,
          email: "fb-smoke-member-#{System.unique_integer([:positive])}@example.com"
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
                         $signatureChoice: String, $publicListingConsent: Boolean) {
      flashbackCreateWish(token: $token, content: $content, visibility: $visibility,
                          signatureChoice: $signatureChoice,
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
    |> Ash.read_one!(authorize?: false)
  end

  defp listed_wish(owner_token, content) do
    assert %{"data" => %{"flashbackCreateWish" => %{"endorsementCount" => 0}}} =
             post_graphql(create_wish_mutation(), %{
               "token" => owner_token,
               "content" => content,
               "visibility" => "public",
               "signatureChoice" => "display_name",
               "publicListingConsent" => true
             })

    wish_by_content(content)
  end

  @add_comment_mutation """
  mutation AddComment($token: String, $wishId: ID!, $content: String!) {
    flashbackAddWishComment(token: $token, wishId: $wishId, content: $content) {
      endorsementCount
      endorsedByMe
    }
  }
  """

  test "flashbackAddWishComment：token 成员可留言公开愿望 → 附议位回显零态" do
    arch = archive()
    owner = person(arch)
    owner_token = token_for(owner)
    wish = listed_wish(owner_token, "一起办一场十周年重聚")

    commenter =
      person(arch, %{email: "commenter-#{System.unique_integer([:positive])}@example.com"})

    commenter_token = token_for(commenter)

    res =
      post_graphql(@add_comment_mutation, %{
        "token" => commenter_token,
        "wishId" => wish.id,
        "content" => "算我一个"
      })

    assert res["errors"] == nil

    # resolver 现状：留言成功返回附议位零态（endorsement_count 0 / endorsed_by_me false）
    assert res["data"]["flashbackAddWishComment"] == %{
             "endorsementCount" => 0,
             "endorsedByMe" => false
           }

    # 副作用：留言确实落库（content + 留言人）
    comment =
      WishComment
      |> Ash.Query.filter(wish_id == ^wish.id and person_id == ^commenter.id)
      |> Ash.read_one!(authorize?: false)

    assert comment.content == "算我一个"
  end

  test "flashbackAddWishComment：返回三态 status(schema non_null 投影;listed wish 上留言恒为 listed)" do
    arch = archive()
    owner = person(arch)
    owner_token = token_for(owner)
    wish = listed_wish(owner_token, "Rust 读书会招募")

    commenter =
      person(arch, %{email: "commenter-#{System.unique_integer([:positive])}@example.com"})

    commenter_token = token_for(commenter)

    res =
      post_graphql(
        """
        mutation AddComment($token: String, $wishId: ID!, $content: String!) {
          flashbackAddWishComment(token: $token, wishId: $wishId, content: $content) {
            endorsementCount
            endorsedByMe
            status
          }
        }
        """,
        %{
          "token" => commenter_token,
          "wishId" => wish.id,
          "content" => "我也加入"
        }
      )

    assert res["errors"] == nil

    # add_comment 对 public+listed wish 恒 listed——这正是与 create_wish 一致的三态口径
    assert res["data"]["flashbackAddWishComment"]["status"] == "listed"
    assert res["data"]["flashbackAddWishComment"]["endorsementCount"] == 0
    assert res["data"]["flashbackAddWishComment"]["endorsedByMe"] == false
  end

  @adjust_today_fog_mutation """
  mutation AdjustTodayFog($token: String, $field: String!, $spans: [FlashbackFogSpanInput!]!) {
    flashbackAdjustTodayFog(token: $token, field: $field, spans: $spans) {
      field
      fogSpans
    }
  }
  """

  test "flashbackAdjustTodayFog：提交非空句级雾面 → 返回与库中均已保存" do
    arch = archive()
    p = person(arch)
    token = token_for(p)

    # 前置：先提交「今天的你」，say 句子才有文本可挂雾面
    {:ok, _} = Flashback.Tokens.submit_today(token, %{say: "十周年快乐！"})

    res =
      post_graphql(@adjust_today_fog_mutation, %{
        "token" => token,
        "field" => "say",
        "spans" => [%{"start" => 0, "len" => 3}]
      })

    assert res["errors"] == nil

    assert %{"field" => "say", "fogSpans" => fog} =
             res["data"]["flashbackAdjustTodayFog"]

    assert [%{"start" => 0, "len" => 3}] = fog["say"]

    # 副作用：雾面持久化到 today.fog_spans
    today =
      Flashback.Today
      |> Ash.Query.filter(person_id == ^p.id)
      |> Ash.read_one!(authorize?: false)

    assert [%{"start" => 0, "len" => 3}] = today.fog_spans["say"]
  end

  @delete_wish_mutation """
  mutation DeleteWish($token: String, $wishId: ID!) {
    flashbackDeleteWish(token: $token, wishId: $wishId)
  }
  """

  test "flashbackDeleteWish：删除自己的许愿 → true（软删）" do
    arch = archive()
    owner = person(arch)
    owner_token = token_for(owner)
    wish = listed_wish(owner_token, "明年再来一场")

    res =
      post_graphql(@delete_wish_mutation, %{"token" => owner_token, "wishId" => wish.id})

    assert res["errors"] == nil
    assert res["data"]["flashbackDeleteWish"] == true

    # 副作用：软删落库
    assert %DateTime{} = Ash.get!(Wish, wish.id, authorize?: false).deleted_at
  end

  @delete_comment_mutation """
  mutation DeleteComment($token: String, $commentId: ID!) {
    flashbackDeleteWishComment(token: $token, commentId: $commentId)
  }
  """

  test "flashbackDeleteWishComment：删除自己的留言 → true（软删）" do
    arch = archive()
    owner = person(arch)
    owner_token = token_for(owner)
    wish = listed_wish(owner_token, "带留言的愿望")

    {:ok, _} = Flashback.Wishes.add_comment(owner.id, wish.id, "自己先留一条")

    comment =
      WishComment |> Ash.Query.filter(wish_id == ^wish.id) |> Ash.read_one!(authorize?: false)

    res =
      post_graphql(@delete_comment_mutation, %{"token" => owner_token, "commentId" => comment.id})

    assert res["errors"] == nil
    assert res["data"]["flashbackDeleteWishComment"] == true

    # 副作用：留言软删落库
    assert %DateTime{} = Ash.get!(WishComment, comment.id, authorize?: false).deleted_at
  end

  @redeem_mutation """
  mutation Redeem($token: String, $channelNote: String!) {
    flashbackRedeem(token: $token, channelNote: $channelNote) { status updated }
  }
  """

  test "flashbackRedeem：首次提交兑换申请 → pending + updated=true" do
    arch = archive()
    owner = person(arch)
    token = token_for(owner)

    res = post_graphql(@redeem_mutation, %{"token" => token, "channelNote" => "支付宝 138****"})

    assert res["errors"] == nil
    assert res["data"]["flashbackRedeem"] == %{"status" => "pending", "updated" => true}
  end
end
