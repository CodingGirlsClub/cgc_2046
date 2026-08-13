defmodule Cgc2046Web.GraphqlSpeakerInvitationTest do
  @moduledoc """
  E-4 #49 GraphQL 接线测试（手写字段端到端解析，ConnCase 经 /api/graphql）。

  覆盖：
  - createSpeakerInvitation：Owner 创建返回 result + 一次性 plainToken；
    非 Owner 失败（payload errors）
  - speakerInvitationCard：公开 token 校验（有效/无效统一错误，无需登录）
  - accept/declineSpeakerInvitation：登录决策 + token 一次性（复用失效）
  - speakerInvitations(eventId)：Owner 列表；普通成员 forbidden

  行为断言主路径在 speaker_flow_test.exs（Ash 层），本测试只证明 GraphQL
  手写 resolver 的接线与错误协议。
  """

  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures

  defp graphql_post(conn, query, token \\ nil) do
    conn =
      if token do
        put_req_header(conn, "authorization", "Bearer #{token}")
      else
        conn
      end

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end

  defp sign_in_token(email) do
    query = """
    mutation {
      signIn(email: "#{email}", password: "#{Fixtures.password()}") {
        id
      }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => query})

    assert %{"data" => %{"signIn" => %{"id" => _id}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  setup %{} do
    admin = Fixtures.platform_admin("gql-spk-admin")
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin)
    owner_token = sign_in_token(admin.email)

    %{admin: admin, workspace: workspace, event: event, owner_token: owner_token}
  end

  test "createSpeakerInvitation → result + plainToken；卡片查询与列表 Owner 可读", %{
    workspace: workspace,
    event: event,
    owner_token: owner_token
  } do
    create_query = """
    mutation {
      createSpeakerInvitation(input: {
        workspaceId: "#{workspace.id}",
        eventId: "#{event.id}",
        speakerName: "嘉宾甲",
        speakerEmail: "gql-speaker@example.com",
        topic: "Elixir 实战"
      }) {
        result { id status }
        plainToken
        errors { message }
      }
    }
    """

    assert %{"data" => %{"createSpeakerInvitation" => created}} =
             build_conn() |> graphql_post(create_query, owner_token)

    assert %{"status" => "invited"} = created["result"]
    token = created["plainToken"]
    assert is_binary(token) and token != ""

    # 卡片公开查询（无需登录）：主题 + Event 公开信息
    card_query = """
    query {
      speakerInvitationCard(token: "#{token}") {
        status
        topic
        event { slug title }
      }
    }
    """

    assert %{"data" => %{"speakerInvitationCard" => card}} =
             build_conn() |> graphql_post(card_query)

    assert card["status"] == "invited"
    assert card["topic"] == "Elixir 实战"
    assert card["event"]["title"] == event.title
    refute Map.has_key?(card, "speakerEmail")

    # Owner 列表
    list_query = """
    query {
      speakerInvitations(eventId: "#{event.id}") { id status }
    }
    """

    assert %{"data" => %{"speakerInvitations" => [invitation]}} =
             build_conn() |> graphql_post(list_query, owner_token)

    assert invitation["id"] == created["result"]["id"]
  end

  test "无效 token 卡片统一错误（无效/已用同形）", %{} do
    query = """
    query {
      speakerInvitationCard(token: "no-such-token") {
        status
      }
    }
    """

    assert %{"data" => %{"speakerInvitationCard" => nil}, "errors" => [%{"message" => message}]} =
             build_conn() |> graphql_post(query)

    assert message =~ "invalid, expired or already used"
  end

  test "accept → accepted；token 一次性复用统一错误；decline 走另一邀请", %{
    workspace: workspace,
    event: event,
    owner_token: owner_token
  } do
    speaker = Fixtures.register_user("gql-spk-speaker")
    speaker_token = sign_in_token(speaker.email)

    create_query = """
    mutation {
      createSpeakerInvitation(input: {
        workspaceId: "#{workspace.id}",
        eventId: "#{event.id}",
        speakerName: "嘉宾乙"
      }) {
        result { id }
        plainToken
        errors { message }
      }
    }
    """

    assert %{"data" => %{"createSpeakerInvitation" => %{"plainToken" => token} = created}} =
             build_conn() |> graphql_post(create_query, owner_token)

    assert is_binary(token)

    accept_query = """
    mutation {
      acceptSpeakerInvitation(token: "#{token}") {
        result { id status }
        errors { message }
      }
    }
    """

    assert %{"data" => %{"acceptSpeakerInvitation" => %{"result" => %{"status" => "accepted"}}}} =
             build_conn() |> graphql_post(accept_query, speaker_token)

    # token 一次性：复用统一错误
    assert %{"data" => %{"acceptSpeakerInvitation" => %{"result" => nil, "errors" => errors}}} =
             build_conn() |> graphql_post(accept_query, speaker_token)

    assert Enum.any?(errors, &(&1["message"] =~ "invalid, expired or already used"))
    _ = created
  end

  test "decline → declined", %{workspace: workspace, event: event, owner_token: owner_token} do
    speaker = Fixtures.register_user("gql-spk-decliner")
    speaker_token = sign_in_token(speaker.email)

    create_query = """
    mutation {
      createSpeakerInvitation(input: {
        workspaceId: "#{workspace.id}",
        eventId: "#{event.id}",
        speakerName: "嘉宾丙"
      }) {
        result { id }
        plainToken
      }
    }
    """

    assert %{"data" => %{"createSpeakerInvitation" => %{"plainToken" => token}}} =
             build_conn() |> graphql_post(create_query, owner_token)

    decline_query = """
    mutation {
      declineSpeakerInvitation(token: "#{token}") {
        result { id status }
        errors { message }
      }
    }
    """

    assert %{"data" => %{"declineSpeakerInvitation" => %{"result" => %{"status" => "declined"}}}} =
             build_conn() |> graphql_post(decline_query, speaker_token)
  end

  test "非 Owner/Admin 不能 create/list（payload/top-level 错误协议）", %{
    workspace: workspace,
    event: event
  } do
    member = Fixtures.register_user("gql-spk-member")
    Fixtures.add_member(workspace, member)
    member_token = sign_in_token(member.email)

    create_query = """
    mutation {
      createSpeakerInvitation(input: {
        workspaceId: "#{workspace.id}",
        eventId: "#{event.id}",
        speakerName: "嘉宾丁"
      }) {
        result { id }
        plainToken
        errors { message }
      }
    }
    """

    assert %{
             "data" => %{
               "createSpeakerInvitation" => %{
                 "result" => nil,
                 "plainToken" => nil,
                 "errors" => errors
               }
             }
           } =
             build_conn() |> graphql_post(create_query, member_token)

    assert errors != []

    list_query = """
    query {
      speakerInvitations(eventId: "#{event.id}") { id }
    }
    """

    assert %{"data" => nil, "errors" => [%{"message" => message}]} =
             build_conn() |> graphql_post(list_query, member_token)

    assert message =~ "forbidden"
  end
end
