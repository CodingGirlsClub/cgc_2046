defmodule Cgc2046Web.OAuthConsentTest do
  @moduledoc """
  U4 授权页（R9/R10、KTD2）：in-process ConnTest 走**真路由**（endpoint → router →
  库的 ConsentRouter → 自定义 `Cgc2046Web.OAuthConsentView`），不 mock 同意视图。

  覆盖：

  - 页面三要素（钓鱼防线）：授权给哪个应用、以哪个 CGC 账号、授权码只回调到哪个地址
    ——账号来自与库判定授权人同源的 actor，用户可控字段（显示名）过 HTML 转义
  - 文案：后端 gettext 中英双份（Accept-Language 协商）
  - 同意路径：302 回调带 code/state/iss；已同意再访问直接发码（库行为回归）；码可换令牌
  - 表单绑定：改表单里的 state/redirect_uri 不生效（协议字段来自密封令牌）
  - 拒绝路径：302 回调带 access_denied + 本地化 error_description（U2 ②：宿主直达用户）
  - 未登录：302 到 web 登录页，return_to 完整携带授权请求（登录后回跳）
  - CSRF：同意 POST 必须过管线里的 protect_from_forgery

  async: false —— 与 OAuthFlowTest 同因（共享 ETS 节流表 + sandbox shared 模式下的
  工具执行进程）。
  """
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.OAuthConsent
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.OAuthFixtures, as: OAuth

  require Ash.Query

  @redirect "http://127.0.0.1:19876/mcp/oauth/callback"

  setup do
    user = Fixtures.register_user("consent-page")
    # 授权页读 host-only 登录 cookie（KTD2）：经 /api/graphql signIn 取真 cookie
    %{user: user, cookie: OAuth.sign_in_cookie(user.email)}
  end

  defp set_display_name(user, name) do
    user
    |> Ash.Changeset.for_update(:update_display_name, %{display_name: name}, authorize?: false)
    |> Ash.update!()
  end

  # Phoenix.ConnTest 的 build_conn/dispatch 会置 `plug_skip_csrf_protection: true`
  # （测试便利）；CSRF 用例显式关掉它，让 protect_from_forgery 真跑。
  defp csrf_enforced(conn), do: put_private(conn, :plug_skip_csrf_protection, false)

  defp consent_rows(user) do
    OAuthConsent
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!(authorize?: false)
  end

  describe "同意页渲染" do
    test "展示应用、账号、能力与回调地址，动作齐备（中文默认）", %{user: user, cookie: cookie} do
      user = set_display_name(user, "陈老师")
      client_id = OAuth.dcr_client([@redirect])

      conn = OAuth.consent_get(cookie, client_id, @redirect, OAuth.pkce_verifier())

      assert conn.status == 200
      body = conn.resp_body

      # 应用（宿主自报的 client_name）与客户端标识
      assert body =~ "opencode"
      assert body =~ client_id

      # 账号：与库判定授权人的 actor 同源（显示名 + 邮箱）
      assert body =~ "陈老师"
      assert body =~ to_string(user.email)

      # 能力：该账号全部工作台 + 单粗粒度 scope
      assert body =~ "该账号的全部工作台"

      # 回调地址：钓鱼防线（用户能核对授权码去向）
      assert body =~ @redirect
      assert body =~ "授权码只会发送到这个地址"

      # 中文默认（产品默认语言，与 web defaultLocale zh-CN 一致）
      assert body =~ ~s(lang="zh-CN")

      # 两动作 + POST 必要字段（库 ConsentRouter 约定）
      assert body =~ ~s(name="action" value="approve")
      assert body =~ ~s(name="action" value="deny")
      assert body =~ ~s(name="_csrf_token" value=")
      assert body =~ ~s(name="consent_request" value=")
      assert body =~ ~s(method="POST")

      # 未同意页不出现任何凭证
      refute body =~ "access_token"
    end

    test "英文浏览器（Accept-Language: en）渲染英文文案", %{cookie: cookie} do
      client_id = OAuth.dcr_client([@redirect])

      conn =
        OAuth.consent_get(cookie, client_id, @redirect, OAuth.pkce_verifier(), [
          {"accept-language", "en-US,en;q=0.9,zh-CN;q=0.8"}
        ])

      assert conn.status == 200
      body = conn.resp_body

      assert body =~ ~s(lang="en")
      assert body =~ "Approve and continue"
      assert body =~ "Callback address"
      assert body =~ "The authorization code is only sent to this address"
      refute body =~ "该账号的全部工作台"
    end

    test "用户可控的显示名经 HTML 转义（不以标签形式进页面）", %{user: user, cookie: cookie} do
      user = set_display_name(user, "<script>alert(1)</script>")
      client_id = OAuth.dcr_client([@redirect])

      body = OAuth.consent_get(cookie, client_id, @redirect, OAuth.pkce_verifier()).resp_body

      refute body =~ "<script>alert(1)</script>"
      assert body =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert body =~ to_string(user.email)
    end
  end

  describe "同意路径" do
    test "同意后 302 回调带 code/state/iss；已同意再访问直接发码；码可换令牌", %{
      user: user,
      cookie: cookie
    } do
      client_id = OAuth.dcr_client([@redirect])
      verifier = OAuth.pkce_verifier()

      page = OAuth.consent_get(cookie, client_id, @redirect, verifier)
      assert page.status == 200

      params = page |> OAuth.consent_post("approve") |> OAuth.callback_params()

      assert is_binary(params["code"])
      assert params["state"] =~ "state-"
      assert params["iss"] == OAuth.issuer_url()
      refute Map.has_key?(params, "error")

      # 已同意（同 client + scope）：库 consented? 命中，不再渲染同意页
      again = OAuth.consent_get(cookie, client_id, @redirect, verifier)
      assert again.status == 302
      assert OAuth.callback_params(again)["code"] != params["code"]

      # 同意页与协议端点接通：拿到的码真能换令牌
      token_conn = OAuth.exchange_code(params["code"], verifier, @redirect, client_id)
      assert token_conn.status == 200
      assert is_binary(Jason.decode!(token_conn.resp_body)["access_token"])

      assert [consent] = consent_rows(user)
      assert consent.client_id == client_id
    end

    test "同意 POST 的表单字段改不动协议参数（state/redirect_uri 来自密封令牌）", %{
      cookie: cookie
    } do
      client_id = OAuth.dcr_client([@redirect])

      page = OAuth.consent_get(cookie, client_id, @redirect, OAuth.pkce_verifier())
      assert page.status == 200

      tampered =
        page
        |> recycle()
        |> post("/oauth/authorize", %{
          "action" => "approve",
          "consent_request" => OAuth.hidden_field(page.resp_body, "consent_request"),
          "_csrf_token" => OAuth.hidden_field(page.resp_body, "_csrf_token"),
          "state" => "attacker-state",
          "redirect_uri" => "http://127.0.0.1:9/evil"
        })

      params = OAuth.callback_params(tampered)
      assert params["state"] =~ "state-"
      refute params["state"] == "attacker-state"
    end

    test "篡改的 consent_request 被拒（400 invalid_request，不回调）", %{cookie: cookie} do
      client_id = OAuth.dcr_client([@redirect])

      page = OAuth.consent_get(cookie, client_id, @redirect, OAuth.pkce_verifier())
      assert page.status == 200

      conn =
        page
        |> recycle()
        |> post("/oauth/authorize", %{
          "action" => "approve",
          "consent_request" => "forged",
          "_csrf_token" => OAuth.hidden_field(page.resp_body, "_csrf_token")
        })

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] == "invalid_request"
      assert get_resp_header(conn, "location") == []
    end
  end

  describe "拒绝路径（U2 ②：error_description 直达宿主用户）" do
    test "拒绝：302 回调带 access_denied + 中文描述，且不落同意行", %{user: user, cookie: cookie} do
      client_id = OAuth.dcr_client([@redirect])

      page = OAuth.consent_get(cookie, client_id, @redirect, OAuth.pkce_verifier())
      assert page.status == 200

      params = page |> OAuth.consent_post("deny") |> OAuth.callback_params()

      assert params["error"] == "access_denied"
      assert params["error_description"] =~ "拒绝"
      assert params["state"] =~ "state-"
      assert params["iss"] == OAuth.issuer_url()
      refute Map.has_key?(params, "code")

      # 拒绝不产生同意：再次访问仍是同意页
      assert OAuth.consent_get(cookie, client_id, @redirect, OAuth.pkce_verifier()).status == 200
      assert consent_rows(user) == []
    end

    test "拒绝（英文浏览器）→ 英文描述", %{cookie: cookie} do
      client_id = OAuth.dcr_client([@redirect])

      page =
        OAuth.consent_get(cookie, client_id, @redirect, OAuth.pkce_verifier(), [
          {"accept-language", "en"}
        ])

      assert page.status == 200

      params = page |> OAuth.consent_post("deny") |> OAuth.callback_params()

      assert params["error"] == "access_denied"
      assert params["error_description"] =~ "denied"
    end

    test "同意的回调不带 error_description（拒绝描述只补在拒绝形状上）", %{cookie: cookie} do
      client_id = OAuth.dcr_client([@redirect])

      page = OAuth.consent_get(cookie, client_id, @redirect, OAuth.pkce_verifier())
      params = page |> OAuth.consent_post("approve") |> OAuth.callback_params()

      refute Map.has_key?(params, "error_description")
    end
  end

  describe "未登录" do
    test "302 到 web 登录页，return_to 完整携带授权请求（登录后回跳授权页）" do
      client_id = OAuth.dcr_client([@redirect])
      verifier = OAuth.pkce_verifier()

      conn = OAuth.consent_get(nil, client_id, @redirect, verifier)

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert location =~ "/login?"

      return_to = URI.decode_query(URI.parse(location).query)["return_to"]
      assert return_to =~ "/oauth/authorize?"

      # 授权请求原样带回（登录后由 web 重新发起到授权页）
      replayed = return_to |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert replayed["client_id"] == client_id
      assert replayed["redirect_uri"] == @redirect
      assert replayed["state"]
      assert replayed["code_challenge"] == OAuth.pkce_challenge(verifier)

      # 库同时写 session（AshAuthentication.Phoenix 登录处理器读 session 而非 query）
      assert get_session(conn, :return_to) == return_to
    end
  end

  describe "CSRF（同意 POST 的管线前置）" do
    test "页面自带的 _csrf_token 过门发码；伪造令牌被拒", %{cookie: cookie} do
      client_id = OAuth.dcr_client([@redirect])

      page = OAuth.consent_get(cookie, client_id, @redirect, OAuth.pkce_verifier())
      assert page.status == 200

      form = %{
        "action" => "approve",
        "consent_request" => OAuth.hidden_field(page.resp_body, "consent_request")
      }

      # 伪造令牌：protect_from_forgery 拦下，不经回调
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        page
        |> recycle()
        |> csrf_enforced()
        |> post("/oauth/authorize", Map.put(form, "_csrf_token", "forged"))
      end

      # 页面令牌：真过 CSRF 门并发出授权码（同意表单在真实管线里可用）
      approved =
        page
        |> recycle()
        |> csrf_enforced()
        |> post(
          "/oauth/authorize",
          Map.put(form, "_csrf_token", OAuth.hidden_field(page.resp_body, "_csrf_token"))
        )

      assert approved.status == 302
      assert is_binary(OAuth.callback_params(approved)["code"])
    end
  end
end
