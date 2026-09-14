defmodule Cgc2046.Accounts.OAuthAuthorizationsTest do
  @moduledoc """
  用户级 OAuth 授权读模型与撤销入口（U5/KTD3）的模块级测试。

  布置全部走 `Cgc2046.OAuthFixtures`（真路由完成协议流程，不 mock 授权服务器）；
  错误与状态分支直接经 U3 的公共入口构造（`revoke_authorization/2`、
  `expire_authorization!/1`、只取码不交换）。

  async: false —— DCR 注册配额与失败节流用共享 ETS 表，且流程测试与
  `Cgc2046Web.OAuthFlowTest` 同域并行会互相干扰。
  """
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.{OAuthAuthorizations, OAuthConsent, OAuthRefreshToken}
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.OAuthFixtures, as: OAuth
  alias Cgc2046.Oauth2Server

  require Ash.Query

  defp entry!(user, client_id) do
    {:ok, entries} = OAuthAuthorizations.list_for(user)
    Enum.find(entries, &(&1.client_id == client_id))
  end

  describe "list_for/1" do
    test "无授权 → 空列表" do
      user = Fixtures.register_user("oauth-authz-empty")
      assert {:ok, []} = OAuthAuthorizations.list_for(user)
    end

    test "授权后一条 active：客户端名/scope/授权时间齐备，最近使用为空（未调用）" do
      user = Fixtures.register_user("oauth-authz-active")
      tokens = OAuth.authorize!(user)

      assert {:ok, [entry]} = OAuthAuthorizations.list_for(user)
      assert entry.client_id == tokens["client_id"]
      assert entry.client_name == "opencode"
      assert entry.scope == Oauth2Server.scope()
      assert %DateTime{} = entry.granted_at
      assert entry.last_used_at == nil
      assert entry.status == :active
    end

    test "首次 MCP 调用后 last_used_at 非空（与 Mcp.Token 同源的首公里「已连接」信号）" do
      user = Fixtures.register_user("oauth-authz-used")
      tokens = OAuth.authorize!(user)
      session_id = OAuth.open_session(tokens["access_token"])
      OAuth.call_tool(tokens["access_token"], session_id, "list_my_workspaces", %{})

      assert %DateTime{} = entry!(user, tokens["client_id"]).last_used_at
      assert entry!(user, tokens["client_id"]).status == :active
    end

    test "连续闲置超过滚动窗口 → idle_expired（链仍在，非撤销）" do
      user = Fixtures.register_user("oauth-authz-idle")
      tokens = OAuth.authorize!(user)
      OAuth.expire_authorization!(tokens)

      assert entry!(user, tokens["client_id"]).status == :idle_expired
    end

    test "宿主自撤销（U3 路径，同意行保留）→ revoked（审计行仍列出）" do
      user = Fixtures.register_user("oauth-authz-host-revoked")
      tokens = OAuth.authorize!(user)

      assert :ok = OAuthRefreshToken.revoke_authorization(user.id, tokens["client_id"])

      entry = entry!(user, tokens["client_id"])
      assert entry.status == :revoked
      # 同意行未动（宿主自撤销不经 web 撤销面）——授权时间仍可读
      assert %DateTime{} = entry.granted_at
      assert consent_row(user, tokens["client_id"])
    end

    test "已同意但未换得凭证（宿主回调失败）→ pending：仅同意行，无链" do
      user = Fixtures.register_user("oauth-authz-pending")
      client_id = OAuth.dcr_client([OAuth.default_redirect_uri()])
      OAuth.code_for(user, client_id, OAuth.default_redirect_uri())

      entry = entry!(user, client_id)
      assert entry.status == :pending
      assert %DateTime{} = entry.granted_at
      assert entry.last_used_at == nil
    end

    test "仅本人：他人的授权不出现在列表里" do
      mine = Fixtures.register_user("oauth-authz-mine")
      other = Fixtures.register_user("oauth-authz-other")
      my_tokens = OAuth.authorize!(mine)
      other_tokens = OAuth.authorize!(other)

      assert {:ok, entries} = OAuthAuthorizations.list_for(mine)
      assert Enum.map(entries, & &1.client_id) == [my_tokens["client_id"]]
      refute Enum.any?(entries, &(&1.client_id == other_tokens["client_id"]))
    end

    test "同一用户多条授权按授权时间新→旧" do
      user = Fixtures.register_user("oauth-authz-multi")
      first = OAuth.authorize!(user)
      second = OAuth.authorize!(user)

      assert {:ok, entries} = OAuthAuthorizations.list_for(user)
      assert Enum.map(entries, & &1.client_id) == [second["client_id"], first["client_id"]]
    end
  end

  describe "revoke/2（web 撤销面）" do
    test "整链撤销 + 撤回同意行：回执 revoked、调用即时 401、重授权需重新过同意页" do
      user = Fixtures.register_user("oauth-authz-revoke")
      tokens = OAuth.authorize!(user)

      # 撤销前：同意行在 → 库直接发码（302），不展示同意页
      cookie = OAuth.sign_in_cookie(user.email)
      verifier = OAuth.pkce_verifier()

      consented =
        OAuth.consent_get(cookie, tokens["client_id"], tokens["redirect_uri"], verifier)

      assert consented.status == 302

      assert {:ok, revoked} = OAuthAuthorizations.revoke(user, tokens["client_id"])
      assert revoked.status == :revoked
      assert revoked.client_id == tokens["client_id"]

      # 即时失效：活跃性回查（KTD8）让下一次调用 401，不等 access token 自然过期
      assert OAuth.post_mcp(tokens["access_token"], OAuth.initialize_body()).status == 401

      # 同意行已撤回 → 重新授权回到同意页（不再静默发码）
      reconsent =
        OAuth.consent_get(cookie, tokens["client_id"], tokens["redirect_uri"], verifier)

      assert reconsent.status == 200
      assert reconsent.resp_body =~ ~s(name="consent_request" value=")

      # 审计行保留：列表仍可回看该 client（链头已撤销），授权时间随同意行撤回而为空
      entry = entry!(user, tokens["client_id"])
      assert entry.status == :revoked
      assert entry.granted_at == nil
    end

    test "他人的 client / 不存在的 client 一律 not_found（不泄露存在性）" do
      mine = Fixtures.register_user("oauth-authz-revoke-mine")
      other = Fixtures.register_user("oauth-authz-revoke-other")
      _my_tokens = OAuth.authorize!(mine)
      other_tokens = OAuth.authorize!(other)

      assert {:error, :not_found} =
               OAuthAuthorizations.revoke(mine, other_tokens["client_id"])

      assert {:error, :not_found} = OAuthAuthorizations.revoke(mine, Ecto.UUID.generate())

      # 他人授权不受影响
      assert entry!(other, other_tokens["client_id"]).status == :active
    end

    test "撤销 pending（已同意未换凭证）：撤回同意行后列表不再有该 client" do
      user = Fixtures.register_user("oauth-authz-revoke-pending")
      client_id = OAuth.dcr_client([OAuth.default_redirect_uri()])
      OAuth.code_for(user, client_id, OAuth.default_redirect_uri())

      assert entry!(user, client_id).status == :pending

      assert {:ok, %{status: :revoked}} = OAuthAuthorizations.revoke(user, client_id)

      # pending 行只由同意行支撑：撤回后整行消失（无链头可审计）
      assert {:ok, []} = OAuthAuthorizations.list_for(user)
      refute consent_row(user, client_id)
    end
  end

  defp consent_row(user, client_id) do
    OAuthConsent
    |> Ash.Query.filter(user_id == ^user.id and client_id == ^client_id)
    |> Ash.read_one!(authorize?: false)
  end
end
