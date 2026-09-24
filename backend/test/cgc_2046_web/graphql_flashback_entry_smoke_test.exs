defmodule Cgc2046Web.GraphqlFlashbackEntrySmokeTest do
  @moduledoc """
  #844 测试 PR（PR 2 flashback 搬迁前的钉测）：只走 `flashback_call` 的
  5 个 GraphQL 字段——flashbackClaim / flashbackMarkRevealed /
  flashbackRecover / flashbackRecoverVerify / flashbackReportWish。
  走真实 POST /api/graphql 入口，钉住当前行为。

  变异验证（随附记录）：M2：`flashback_call/1` 改为恒返回错误 →
  本文件全部测试红（mutation 本体与 fixture 的 flashbackCreateWish
  均经该入口）。红后还原复跑全绿。M4：Recover.dispatch 邮箱命中
  分支改为不发送 → recover 的外发断言红。
  """

  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.TokenCredential
  alias Cgc2046.AccountsFixtures
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Person, Token, Wish}

  require Ash.Query

  @moduletag :capture_log

  # 各文件自带 fixture 是现有惯例，抽成共享模块不在 #844 范围。
  defp post_graphql(query, user, variables) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")

    conn =
      if user do
        token = sign_in_token(user)
        put_req_header(conn, "authorization", "Bearer #{token}")
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

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => mutation})

    conn.resp_cookies["cgc_token"].value
  end

  defp archive do
    Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: "fb-smoke-entry-#{System.unique_integer([:positive])}",
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
          email: "fb-smoke-entry-#{System.unique_integer([:positive])}@example.com",
          phone: "13900000001"
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

  @claim_mutation """
  mutation Claim($token: String) {
    flashbackClaim(token: $token) { bound boundCount maskedPhone }
  }
  """

  test "flashbackClaim：登录用户带 token → 绑定成功，掩码回显" do
    arch = archive()
    p = person(arch, %{phone: "13911112233"})
    token = token_for(p)
    user = AccountsFixtures.register_user("fb-smoke-claim")

    res = post_graphql(@claim_mutation, user, %{"token" => token})
    assert res["errors"] == nil

    assert %{"bound" => true, "boundCount" => 1, "maskedPhone" => masked} =
             res["data"]["flashbackClaim"]

    assert masked =~ "****"
  end

  @mark_revealed_mutation """
  mutation Mark($token: String!) {
    flashbackMarkRevealed(token: $token) { recorded }
  }
  """

  test "flashbackMarkRevealed：有效 token → recorded=true（四率之 revealed）" do
    arch = archive()
    token = token_for(person(arch))

    res = post_graphql(@mark_revealed_mutation, nil, %{"token" => token})
    assert res["errors"] == nil
    assert res["data"]["flashbackMarkRevealed"] == %{"recorded" => true}
  end

  @recover_mutation """
  mutation Recover($identifier: String!) {
    flashbackRecover(identifier: $identifier) { dispatched }
  }
  """

  # Swoosh 测试适配器的进程消息可观察面（同 flashback/recover_normalize_test.exs）
  defp collect_recovery_mails do
    receive do
      {:email, mail} ->
        if String.contains?(mail.subject, "闪念间档案入口"),
          do: [mail | collect_recovery_mails()],
          else: collect_recovery_mails()
    after
      0 -> []
    end
  end

  test "flashbackRecover：命中与未命中同形 dispatched=true，效果差别在外发" do
    arch = archive()
    email = "fb-smoke-recover-#{System.unique_integer([:positive])}@example.com"
    person(arch, %{email: email})

    res = post_graphql(@recover_mutation, nil, %{"identifier" => email})
    assert res["errors"] == nil
    assert res["data"]["flashbackRecover"] == %{"dispatched" => true}

    # 副作用（同形返回下唯一可观察的差别）：命中 → 恢复邮件确实发出
    [mail] = collect_recovery_mails()
    assert mail.to == [{"", email}]
    assert String.contains?(mail.text_body, "/flashback/enter?token=")

    # 对照：未命中同样 dispatched=true，但不外发
    miss = "fb-smoke-miss-#{System.unique_integer([:positive])}@example.com"

    res_miss = post_graphql(@recover_mutation, nil, %{"identifier" => miss})
    assert res_miss["errors"] == nil
    assert res_miss["data"]["flashbackRecover"] == %{"dispatched" => true}
    assert collect_recovery_mails() == []
  end

  @recover_verify_mutation """
  mutation Verify($identifier: String!, $code: String!) {
    flashbackRecoverVerify(identifier: $identifier, code: $code) { bound cards { personId surnameMasked } }
  }
  """

  test "flashbackRecoverVerify：手机验证码通过 → find-or-create + 绑定档案，返回脱敏卡" do
    arch = archive()

    phone =
      "1390000#{System.unique_integer([:positive]) |> rem(10_000) |> Integer.to_string() |> String.pad_leading(4, "0")}"

    person(arch, %{
      phone: phone,
      full_name: "李盼",
      surname: "李",
      email: "fb-smoke-verify-#{System.unique_integer([:positive])}@example.com"
    })

    # 同生产口径：normalize → issue（验证码经 PhoneVerificationCode 直发，U2 注记）
    {:ok, normalized} = Cgc2046.Accounts.PhoneNumber.normalize(phone)
    {:ok, code, _} = Cgc2046.Accounts.PhoneVerificationCode.issue(normalized, :register)

    res = post_graphql(@recover_verify_mutation, nil, %{"identifier" => phone, "code" => code})
    assert res["errors"] == nil

    assert %{"bound" => true, "cards" => [%{"surnameMasked" => "李*"}]} =
             res["data"]["flashbackRecoverVerify"]
  end

  @report_mutation """
  mutation Report($wishId: ID!, $reasonType: String!, $reasonFree: String, $anonVoterKey: String) {
    flashbackReportWish(wishId: $wishId, reasonType: $reasonType,
                        reasonFree: $reasonFree, anonVoterKey: $anonVoterKey) {
      reportId status
    }
  }
  """

  test "flashbackReportWish：匿名设备键可报 → pending 入队" do
    arch = archive()
    owner = person(arch)
    token = token_for(owner)

    assert %{"data" => %{"flashbackCreateWish" => %{"endorsementCount" => 0}}} =
             post_graphql(create_wish_mutation(), nil, %{
               "token" => token,
               "content" => "一起办一场十周年重聚",
               "visibility" => "public",
               "signatureChoice" => "display_name",
               "publicListingConsent" => true
             })

    wish = wish_by_content("一起办一场十周年重聚")

    res =
      post_graphql(@report_mutation, nil, %{
        "wishId" => wish.id,
        "reasonType" => "spam",
        "anonVoterKey" => "a:smoke-report"
      })

    assert res["errors"] == nil
    assert %{"reportId" => report_id, "status" => "pending"} = res["data"]["flashbackReportWish"]
    assert is_binary(report_id)
  end
end
