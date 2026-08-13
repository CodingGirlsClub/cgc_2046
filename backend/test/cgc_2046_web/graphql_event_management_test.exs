defmodule Cgc2046Web.GraphqlEventManagementTest do
  @moduledoc """
  E-11 #127 GraphQL mutation 链路：createEvent → updateEvent（visibility 切换）→
  launchEvent → closeEvent。管理面产品入口（此前活动只能经 AshAdmin 操作）。
  """

  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Event

  defp create_event_mutation(workspace_id, attrs) do
    """
    mutation {
      createEvent(input: #{json_attrs(attrs, workspace_id)}) {
        result { id title status visibility workspaceId }
        errors { message }
      }
    }
    """
  end

  defp json_attrs(attrs, workspace_id) do
    workspace_pair = ~s(workspaceId: "#{workspace_id}")

    pairs =
      Enum.map_join(attrs, ", ", fn
        {k, v} when is_binary(v) -> ~s(#{k}: "#{v}")
        {k, v} when is_boolean(v) -> "#{k}: #{v}"
        {k, v} when is_integer(v) -> "#{k}: #{v}"
        {k, v} when is_atom(v) -> ~s(#{k}: "#{v}")
      end)

    if pairs == "" do
      "{#{workspace_pair}}"
    else
      "{#{workspace_pair}, #{pairs}}"
    end
  end

  defp action_mutation(action, event_id) do
    """
    mutation {
      #{action}(id: "#{event_id}") {
        result { id status visibility }
        errors { message }
      }
    }
    """
  end

  test "Owner 经 GraphQL 完成 draft → open → closed 全流程 + visibility 切换" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    token = sign_in_token(admin)

    # 创建（默认 draft + public；workspaceId 经入参注入 tenant）
    create_response =
      graphql(
        create_event_mutation(workspace.id, %{title: "管理面测试活动", enrollment_policy: :open}),
        token
      )

    assert %{"data" => %{"createEvent" => %{"result" => created, "errors" => []}}} =
             create_response

    assert created["status"] == "draft"
    assert created["visibility"] == "public"
    assert created["workspaceId"] == workspace.id

    # 编辑：visibility → workspace
    update_response =
      graphql(
        """
        mutation {
          updateEvent(id: "#{created["id"]}", input: {visibility: "workspace"}) {
            result { id visibility }
            errors { message }
          }
        }
        """,
        token
      )

    assert %{"data" => %{"updateEvent" => %{"result" => updated, "errors" => []}}} =
             update_response

    assert updated["visibility"] == "workspace"

    # launch → open
    assert %{"data" => %{"launchEvent" => %{"result" => launched, "errors" => []}}} =
             graphql(action_mutation("launchEvent", created["id"]), token)

    assert launched["status"] == "open"

    # close → closed
    assert %{"data" => %{"closeEvent" => %{"result" => closed, "errors" => []}}} =
             graphql(action_mutation("closeEvent", created["id"]), token)

    assert closed["status"] == "closed"

    reloaded = Ash.get!(Event, created["id"], authorize?: false)
    assert reloaded.status == :closed
    assert reloaded.visibility == :workspace
  end

  test "普通成员不能 createEvent（写策略 Owner/Admin）" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    member = Fixtures.register_user("gql-event-mgmt-member")
    Fixtures.add_member(workspace, member)

    response =
      graphql(
        create_event_mutation(workspace.id, %{title: "越权创建", enrollment_policy: :open}),
        sign_in_token(member)
      )

    assert %{"data" => %{"createEvent" => %{"result" => nil, "errors" => errors}}} = response
    assert errors != []
  end

  defp sign_in_token(user) do
    mutation = """
    mutation {
      signIn(email: "#{user.email}", password: "#{Fixtures.password()}") { id }
    }
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
