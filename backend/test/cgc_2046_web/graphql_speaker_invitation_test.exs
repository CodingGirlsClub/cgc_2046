defmodule Cgc2046Web.GraphqlSpeakerInvitationTest do
  @moduledoc """
  E-4 #49 GraphQL 接线测试（手写字段端到端解析，ConnCase 经 /api/graphql）。

  覆盖：
  - createSpeakerInvitation：Owner 创建返回 result + 一次性 plainToken；
    非 Owner 失败（payload errors）
  - speakerInvitationCard：公开 token 校验（有效/无效统一错误，无需登录）
  - accept/declineSpeakerInvitation：登录决策 + token 一次性（复用失效）
  - saveSpeakerMaterials：Speaker 本人存材料（落 run facts）→ complete 可达；
    无关用户 forbidden
  - speakerInvitations(eventId)：Owner 列表；普通成员 forbidden

  行为断言主路径在 speaker_flow_test.exs（Ash 层），本测试只证明 GraphQL
  手写 resolver 的接线与错误协议。
  """

  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Events.SpeakerInvitation
  alias Cgc2046.Workflows.WorkflowRun

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

  test "saveSpeakerMaterials：Speaker 本人可存 → 材料落 run facts → completeSpeakerInvitation 达 completed（run succeeded）",
       %{workspace: workspace, event: event, owner_token: owner_token} do
    # accept 双重校验（token + 账号匹配）：speaker 以被邀请邮箱注册
    speaker = Fixtures.register_user_with_email("gql-speaker-m@example.com")
    speaker_token = sign_in_token(speaker.email)

    invitation_id =
      create_and_accept(workspace, event, owner_token, speaker_token, speaker.email)

    materials = %{"title" => "分享大纲", "link" => "https://example.com/slides"}

    save_query = """
    mutation {
      saveSpeakerMaterials(
        invitationId: "#{invitation_id}",
        materials: #{Jason.encode!(Jason.encode!(materials))}
      ) {
        result { id status }
        errors { message }
      }
    }
    """

    assert %{
             "data" => %{
               "saveSpeakerMaterials" => %{"result" => %{"status" => "accepted"}, "errors" => []}
             }
           } =
             build_conn() |> graphql_post(save_query, speaker_token)

    # 材料产出落点：WorkflowRun.facts["materials"]（邀请设计 §5.3）
    invitation = Ash.get!(SpeakerInvitation, invitation_id, authorize?: false)
    run = Ash.get!(WorkflowRun, invitation.workflow_run_id, authorize?: false)
    assert run.facts["materials"] == materials

    complete_query = """
    mutation {
      completeSpeakerInvitation(id: "#{invitation_id}") {
        result { id status }
        errors { message }
      }
    }
    """

    assert %{
             "data" => %{
               "completeSpeakerInvitation" => %{
                 "result" => %{"status" => "completed"},
                 "errors" => []
               }
             }
           } =
             build_conn() |> graphql_post(complete_query, speaker_token)

    # M2 完成 → run 镜像 succeeded（materials 门控放行）
    assert Ash.get!(WorkflowRun, run.id, authorize?: false).status == :succeeded
  end

  test "saveSpeakerMaterials：无关用户 forbidden", %{
    workspace: workspace,
    event: event,
    owner_token: owner_token
  } do
    speaker = Fixtures.register_user_with_email("gql-speaker-n@example.com")
    speaker_token = sign_in_token(speaker.email)
    outsider = Fixtures.register_user("gql-spk-outsider")
    outsider_token = sign_in_token(outsider.email)

    invitation_id =
      create_and_accept(workspace, event, owner_token, speaker_token, speaker.email)

    save_query = """
    mutation {
      saveSpeakerMaterials(
        invitationId: "#{invitation_id}",
        materials: #{Jason.encode!(Jason.encode!(%{"title" => "劫持材料"}))}
      ) {
        result { id status }
        errors { message code }
      }
    }
    """

    assert %{
             "data" => %{
               "saveSpeakerMaterials" => %{"result" => nil, "errors" => errors}
             }
           } =
             build_conn() |> graphql_post(save_query, outsider_token)

    assert Enum.any?(errors, &(&1["message"] =~ "forbidden"))
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

  # 布置：Owner 创建定向邀请（speakerEmail = 已登录 speaker 邮箱）→ speaker accept，
  # 返回 invitation id（saveSpeakerMaterials / completeSpeakerInvitation 测试共享）。
  defp create_and_accept(workspace, event, owner_token, speaker_token, speaker_email) do
    create_query = """
    mutation {
      createSpeakerInvitation(input: {
        workspaceId: "#{workspace.id}",
        eventId: "#{event.id}",
        speakerName: "嘉宾己",
        speakerEmail: "#{speaker_email}"
      }) {
        result { id status }
        plainToken
        errors { message }
      }
    }
    """

    assert %{
             "data" => %{
               "createSpeakerInvitation" => %{
                 "result" => %{"id" => invitation_id},
                 "plainToken" => token
               }
             }
           } =
             build_conn() |> graphql_post(create_query, owner_token)

    accept_query = """
    mutation {
      acceptSpeakerInvitation(token: "#{token}") {
        result { id status }
        errors { message }
      }
    }
    """

    assert %{
             "data" => %{
               "acceptSpeakerInvitation" => %{"result" => %{"status" => "accepted"}}
             }
           } =
             build_conn() |> graphql_post(accept_query, speaker_token)

    invitation_id
  end
end
