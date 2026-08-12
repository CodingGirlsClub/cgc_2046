defmodule Cgc2046Web.GraphqlMiniprogramCodeTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures

  setup do
    Req.Test.stub(Cgc2046.MiniprogramClientStub, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.host, conn.request_path} do
        {"api.weixin.qq.com", "/cgi-bin/token"} ->
          Req.Test.json(conn, %{"access_token" => "wechat-code-token", "expires_in" => 7200})

        {"api.weixin.qq.com", "/wxa/getwxacodeunlimit"} ->
          Plug.Conn.send_resp(conn, 200, <<137, 80, 78, 71, 9, 9, 9>>)

        other ->
          raise "unexpected request: #{inspect(other)}"
      end
    end)

    :ok
  end

  test "Owner 生成小程序码；scene 入座一次成功、重放失败" do
    platform_admin = Fixtures.platform_admin("gql-code-platform")
    owner = Fixtures.register_user("gql-code-owner")
    first_user = Fixtures.register_user("gql-code-first")
    second_user = Fixtures.register_user("gql-code-second")
    workspace = Fixtures.create_workspace(platform_admin)
    Fixtures.add_member(workspace, owner, [:owner])

    generate = """
    mutation {
      generateMiniProgramCode(workspaceId: "#{workspace.id}", platform: "wechat") {
        invitationId
        platform
        scene
        codeBase64
        expiresAt
      }
    }
    """

    assert %{"data" => %{"generateMiniProgramCode" => generated}} =
             graphql(generate, sign_in_token(owner))

    assert generated["platform"] == "wechat"
    assert generated["scene"] =~ ~r/^[A-Za-z0-9_]{1,32}$/
    assert is_binary(generated["codeBase64"])

    admit = fn scene ->
      """
      mutation {
        admitMemberByToken(scene: "#{scene}") { id status acceptedBy }
      }
      """
    end

    assert %{"data" => %{"admitMemberByToken" => %{"status" => "used"}}} =
             graphql(admit.(generated["scene"]), sign_in_token(first_user))

    replay = graphql(admit.(generated["scene"]), sign_in_token(second_user))
    assert Enum.any?(replay["errors"], &String.contains?(&1["message"], "used"))
  end

  test "普通成员不能生成码；非法 scene 在查询前 fail-closed" do
    platform_admin = Fixtures.platform_admin("gql-code-deny-platform")
    member = Fixtures.register_user("gql-code-member")
    workspace = Fixtures.create_workspace(platform_admin)
    Fixtures.add_member(workspace, member, [:member])

    generate = """
    mutation {
      generateMiniProgramCode(workspaceId: "#{workspace.id}", platform: "wechat") {
        scene
      }
    }
    """

    denied = graphql(generate, sign_in_token(member))
    assert Enum.any?(denied["errors"], &(&1["code"] == "forbidden"))

    injection = """
    mutation { admitMemberByToken(scene: "../../etc/passwd") { id } }
    """

    invalid = graphql(injection, sign_in_token(member))
    assert Enum.any?(invalid["errors"], &(&1["code"] == "invalid_scene"))
  end

  test "已过期 scene 不能入座" do
    platform_admin = Fixtures.platform_admin("gql-code-expiry-platform")
    owner = Fixtures.register_user("gql-code-expiry-owner")
    learner = Fixtures.register_user("gql-code-expiry-learner")
    workspace = Fixtures.create_workspace(platform_admin)
    Fixtures.add_member(workspace, owner, [:owner])

    generated =
      graphql(
        """
        mutation {
          generateMiniProgramCode(workspaceId: "#{workspace.id}", platform: "wechat") { scene }
        }
        """,
        sign_in_token(owner)
      )

    scene = get_in(generated, ["data", "generateMiniProgramCode", "scene"])

    Cgc2046.Repo.query!(
      "UPDATE miniprogram_codes SET expires_at = NOW() - INTERVAL '1 minute' WHERE scene = $1",
      [scene]
    )

    expired =
      graphql(
        "mutation { admitMemberByToken(scene: \"#{scene}\") { id } }",
        sign_in_token(learner)
      )

    assert Enum.any?(expired["errors"], &(&1["code"] == "invalid_or_expired_scene"))
  end

  test "订阅消息授权 mutation 按平台限流" do
    table = Cgc2046Web.Plugs.RateLimit.table()
    previous_config = Application.get_env(:cgc_2046, Cgc2046Web.Plugs.RateLimit)
    :ets.delete_all_objects(table)
    Application.put_env(:cgc_2046, Cgc2046Web.Plugs.RateLimit, max_attempts: 3)

    on_exit(fn ->
      :ets.delete_all_objects(table)
      Application.put_env(:cgc_2046, Cgc2046Web.Plugs.RateLimit, previous_config)
    end)

    user = Fixtures.register_user("gql-consent-rate-limit")
    token = sign_in_token(user)

    mutation = """
    mutation {
      grantMiniProgramNotificationConsent(platform: "wechat", templateKey: "approval_result")
    }
    """

    for expected <- 1..3 do
      assert %{"data" => %{"grantMiniProgramNotificationConsent" => ^expected}} =
               graphql(mutation, token)
    end

    limited = graphql(mutation, token)
    assert Enum.any?(limited["errors"], &(&1["code"] == "rate_limited"))
  end

  defp sign_in_token(user) do
    mutation = """
    mutation { signIn(email: "#{user.email}", password: "#{Fixtures.password()}") { id } }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => mutation})

    assert %{"data" => %{"signIn" => %{"id" => _}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  defp graphql(query, token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end
end
