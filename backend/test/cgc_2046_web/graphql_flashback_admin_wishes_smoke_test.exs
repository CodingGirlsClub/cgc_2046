defmodule Cgc2046Web.GraphqlFlashbackAdminWishesSmokeTest do
  @moduledoc """
  #844 测试 PR（PR 2 flashback 搬迁前的钉测）：`with_admin` 门控的
  8 个 GraphQL 字段——flashbackAdminArchives /
  flashbackAdminResendOutreach / flashbackAdminWishInbox /
  flashbackAdminWishReports（query）与 flashbackAdminUpdateRedemption /
  flashbackAdminSetWishHidden / flashbackAdminDismissReport /
  flashbackAdminApproveReport（mutation）。走真实 POST /api/graphql
  入口，钉住当前行为（成功路径）。

  变异验证（随附记录）：
  - M1：`with_admin/2` 的 platform_admin 分支改为返回 forbidden →
    本文件 8 条测试全红；
  - M2：`flashback_call/1` 改为恒返回错误 → 4 个 mutation 字段红；
    inbox / reports 两条 query 因 fixture 走 flashbackCreateWish 也红；
    archives / resend_outreach 不经 flashback_call 且不用该 fixture，
    保持绿（由 M1 钉住）。
  - M4（跳过写、保留成功返回）：set_wish_hidden 置 hidden_at: nil →
    set_wish_hidden / approve_report 两条的落库断言红（返回值断言随
    行为一并红）；approve_report 跳过 set_wish_hidden 联动 → 仅
    approve 的落库断言红。
  （红/绿输出见 PR 描述。）
  """

  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.TokenCredential
  alias Cgc2046.AccountsFixtures
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Person, Token, Wish}

  require Ash.Query

  @moduletag :capture_log

  setup do
    Req.Test.stub(Cgc2046.SmsSendCloudStub, fn conn ->
      Req.Test.json(conn, %{"result" => true})
    end)

    :ok
  end

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
      key: "fb-smoke-admin-#{System.unique_integer([:positive])}",
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
          email: "fb-smoke-admin-#{System.unique_integer([:positive])}@example.com"
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

  # 经真实 GraphQL create 建 wish（visibility 可选），返回 wish 记录
  defp create_wish(token, content, visibility) do
    assert %{"data" => %{"flashbackCreateWish" => %{"endorsementCount" => 0}}} =
             post_graphql(create_wish_mutation(), nil, %{
               "token" => token,
               "content" => content,
               "visibility" => visibility,
               "signatureChoice" => "display_name",
               "publicListingConsent" => true
             })

    wish_by_content(content)
  end

  defp create_report(wish_id) do
    {:ok, report} =
      Flashback.Reports.report("wish", wish_id, "spam",
        actor_user_id: nil,
        anon_voter_key: "a:smoke-admin",
        reason_free: nil,
        remote_ip: "127.0.0.1"
      )

    report
  end

  @archives_query """
  query { flashbackAdminArchives { key name city occurredOn } }
  """

  test "flashbackAdminArchives：admin 可读场次列表（key 指路发送入口）" do
    admin = AccountsFixtures.platform_admin("fb-smoke-adm-archives")
    arch = archive()

    res = post_graphql(@archives_query, admin, %{})
    assert res["errors"] == nil

    keys = Enum.map(res["data"]["flashbackAdminArchives"], & &1["key"])
    assert arch.key in keys
  end

  @resend_query """
  query Resend($personId: ID!, $template: String!, $channel: String) {
    flashbackAdminResendOutreach(personId: $personId, template: $template, channel: $channel) {
      queued skipped
    }
  }
  """

  test "flashbackAdminResendOutreach：可达未认领者重发 → resend 批次入队 1 跳过 0" do
    admin = AccountsFixtures.platform_admin("fb-smoke-adm-resend")
    arch = archive()
    p = person(arch)

    res = post_graphql(@resend_query, admin, %{"personId" => p.id, "template" => "reconnect"})
    assert res["errors"] == nil
    assert res["data"]["flashbackAdminResendOutreach"] == %{"queued" => 1, "skipped" => 0}
  end

  @inbox_query """
  query { flashbackAdminWishInbox { wishId content city signature insertedAt wisherMasked } }
  """

  test "flashbackAdminWishInbox：private 愿望 + 作者联系方式可读（admin-only 面）" do
    admin = AccountsFixtures.platform_admin("fb-smoke-adm-inbox")
    arch = archive()
    wisher = person(arch)
    token = token_for(wisher)
    wish = create_wish(token, "说给主办方听的悄悄话", "private")

    res = post_graphql(@inbox_query, admin, %{})
    assert res["errors"] == nil

    entries = res["data"]["flashbackAdminWishInbox"]

    assert [%{"wishId" => wish_id, "content" => "说给主办方听的悄悄话", "wisherMasked" => "王**"}] =
             Enum.filter(entries, &(&1["wishId"] == wish.id))

    assert is_binary(wish_id)
  end

  @reports_query """
  query { flashbackAdminWishReports { reportId targetType targetId reasonType status } }
  """

  test "flashbackAdminWishReports：pending 举报按序可读" do
    admin = AccountsFixtures.platform_admin("fb-smoke-adm-reports")
    arch = archive()
    owner = person(arch)
    token = token_for(owner)
    wish = create_wish(token, "被举报的愿望", "public")
    report = create_report(wish.id)

    res = post_graphql(@reports_query, admin, %{})
    assert res["errors"] == nil

    entries = res["data"]["flashbackAdminWishReports"]

    assert [
             %{
               "reportId" => report_id,
               "targetType" => "wish",
               "reasonType" => "spam",
               "status" => "pending"
             }
           ] =
             Enum.filter(entries, &(&1["reportId"] == report.id))

    assert is_binary(report_id)
  end

  @update_redemption_mutation """
  mutation UpdateRedemption($id: ID!, $status: String!, $handledNote: String) {
    flashbackAdminUpdateRedemption(id: $id, status: $status, handledNote: $handledNote) {
      id status
    }
  }
  """

  test "flashbackAdminUpdateRedemption：pending → contacted 人工流转" do
    admin = AccountsFixtures.platform_admin("fb-smoke-adm-redemption")
    arch = archive()
    p = person(arch)

    {:ok, _} = Flashback.AdminStats.submit(p.id, "支付宝 138****")

    redemption =
      Flashback.Redemption
      |> Ash.Query.filter(person_id == ^p.id)
      |> Ash.read_one!(authorize?: false)

    res =
      post_graphql(@update_redemption_mutation, admin, %{
        "id" => redemption.id,
        "status" => "contacted",
        "handledNote" => "已电话确认"
      })

    assert res["errors"] == nil

    assert %{"id" => id, "status" => "contacted"} =
             res["data"]["flashbackAdminUpdateRedemption"]

    assert id == redemption.id
  end

  @set_wish_hidden_mutation """
  mutation SetHidden($wishId: ID!, $hidden: Boolean!) {
    flashbackAdminSetWishHidden(wishId: $wishId, hidden: $hidden) { wishId hidden }
  }
  """

  test "flashbackAdminSetWishHidden：下架公开愿望 → hidden=true" do
    admin = AccountsFixtures.platform_admin("fb-smoke-adm-hidden")
    arch = archive()
    owner = person(arch)
    token = token_for(owner)
    wish = create_wish(token, "要被下架的愿望", "public")

    res = post_graphql(@set_wish_hidden_mutation, admin, %{"wishId" => wish.id, "hidden" => true})
    assert res["errors"] == nil

    assert %{"wishId" => wish_id, "hidden" => true} =
             res["data"]["flashbackAdminSetWishHidden"]

    assert wish_id == wish.id

    # 副作用：下架状态落库（返回的 hidden 可能只是输入回显）
    assert %DateTime{} = Ash.get!(Wish, wish.id, authorize?: false).hidden_at
  end

  @dismiss_mutation """
  mutation Dismiss($reportId: ID!) {
    flashbackAdminDismissReport(reportId: $reportId) { reportId status }
  }
  """

  test "flashbackAdminDismissReport：驳回举报 → dismissed" do
    admin = AccountsFixtures.platform_admin("fb-smoke-adm-dismiss")
    arch = archive()
    owner = person(arch)
    token = token_for(owner)
    wish = create_wish(token, "被误报的愿望", "public")
    report = create_report(wish.id)

    res = post_graphql(@dismiss_mutation, admin, %{"reportId" => report.id})
    assert res["errors"] == nil

    assert %{"reportId" => report_id, "status" => "dismissed"} =
             res["data"]["flashbackAdminDismissReport"]

    assert report_id == report.id
  end

  @approve_mutation """
  mutation Approve($reportId: ID!) {
    flashbackAdminApproveReport(reportId: $reportId) { reportId status }
  }
  """

  test "flashbackAdminApproveReport：批准举报 → actioned（联动下架）" do
    admin = AccountsFixtures.platform_admin("fb-smoke-adm-approve")
    arch = archive()
    owner = person(arch)
    token = token_for(owner)
    wish = create_wish(token, "确属违规的愿望", "public")
    report = create_report(wish.id)

    res = post_graphql(@approve_mutation, admin, %{"reportId" => report.id})
    assert res["errors"] == nil

    assert %{"reportId" => report_id, "status" => "actioned"} =
             res["data"]["flashbackAdminApproveReport"]

    assert report_id == report.id

    # 副作用：联动下架落库（批准举报 → 目标愿望 hidden_at 置位）
    assert %DateTime{} = Ash.get!(Wish, wish.id, authorize?: false).hidden_at
  end
end
