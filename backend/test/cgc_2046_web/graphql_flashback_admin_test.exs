defmodule Cgc2046Web.GraphqlFlashbackAdminTest do
  @moduledoc """
  U11 看板 GraphQL 面：PlatformAdmin gate——非 admin（未登录/普通用户）被拒。
  变异验证（随附记录）：去掉 with_admin gate（改直接调用）→ forbidden 断言红。
  """
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures

  @moduletag :capture_log

  @stats_query """
  query { flashbackAdminStats {
    memory { delivered linkOpened: link_opened revealed sentToWall: sent_to_wall intentSubmitted: intent_submitted }
    dream { delivered linkOpened: link_opened revealed sentToWall: sent_to_wall intentSubmitted: intent_submitted }
    overall { delivered }
  } }
  """

  @redemptions_query """
  query { flashbackAdminRedemptions { id status channelNote: channel_note maskedName: masked_name } }
  """

  defp post_graphql(query, user \\ nil) do
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

    conn |> post("/api/graphql", %{"query" => query}) |> json_response(200)
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

  test "未登录 → forbidden（不泄露数据）" do
    res = post_graphql(@stats_query)
    assert [%{"code" => "unauthorized"}] = res["errors"]

    res = post_graphql(@redemptions_query)
    assert [%{"code" => "unauthorized"}] = res["errors"]
  end

  test "普通用户 → forbidden" do
    user = AccountsFixtures.register_user("fb-admin-plain")

    res = post_graphql(@stats_query, user)
    assert [%{"code" => "forbidden"}] = res["errors"]
  end

  test "platform_admin → 四率与兑换队列可读（空库零值）" do
    admin = AccountsFixtures.platform_admin("fb-admin-admin")

    res = post_graphql(@stats_query, admin)
    stats = res["data"]["flashbackAdminStats"]
    assert stats["overall"]["delivered"] == 0
    assert stats["memory"]["linkOpened"] == 0

    res = post_graphql(@redemptions_query, admin)
    assert res["data"]["flashbackAdminRedemptions"] == []
  end
end
