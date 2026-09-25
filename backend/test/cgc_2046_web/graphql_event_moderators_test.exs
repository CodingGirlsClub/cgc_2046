defmodule Cgc2046Web.GraphqlEventModeratorsTest do
  @moduledoc """
  #537 指派锚与回显投影的 GraphQL 端到端：

  - `assignEventModerator(userId:)` 接受邮箱 / CGC 编号 / 用户 ID 三锚点
    （域层 `Accounts.UserResolution` 解析后落 UUID）；
  - 未命中错误 `user_not_found` 走 payload errors（code 直达前端 i18n，
    不炸顶层），防枚举统一文案；
  - `eventModerators` 投影带平铺回显字段（displayName / memberNumber /
    assignedBy 同 fallback 链数据面）。
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Moderators
  alias Cgc2046.EventsFixtures

  test "邮箱锚指派成功；列表投影带 displayName / memberNumber / assignedBy" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    moderator = Fixtures.register_user_with_email("gql-anchor-mod@example.com")
    Fixtures.add_member(workspace, moderator, [:learner])
    event = EventsFixtures.create_event(workspace, owner)

    # owner 设 display_name：assignedBy 回显可见
    owner
    |> Ash.Changeset.for_update(:update_display_name, %{display_name: "台主"})
    |> Ash.update!(actor: owner)

    assert %{"data" => %{"assignEventModerator" => %{"errors" => [], "result" => result}}} =
             graphql(
               assign_mutation(workspace.id, event.id, "Gql-Anchor-Mod@Example.com"),
               sign_in_token(owner)
             )

    assert result["userId"] == moderator.id

    assert %{"data" => %{"eventModerators" => rows}} =
             graphql(list_query(workspace.id, event.id), sign_in_token(owner))

    row = Enum.find(rows, &(&1["userId"] == moderator.id))
    # display_name 未设置 → null；memberNumber 恒有值；assignedBy 回显 owner
    assert row["userDisplayName"] == nil
    assert row["userMemberNumber"] == expected_member_number(moderator.id)
    assert row["assignedByDisplayName"] == "台主"
    assert row["assignedByMemberNumber"] == expected_member_number(owner.id)
  end

  test "不存在的锚统一 user_not_found 进 payload errors（顶层不炸）" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    event = EventsFixtures.create_event(workspace, owner)

    assert %{"data" => %{"assignEventModerator" => payload}} =
             graphql(
               assign_mutation(workspace.id, event.id, "nobody@example.com"),
               sign_in_token(owner)
             )

    assert payload["result"] == nil
    assert [%{"code" => "user_not_found"}] = payload["errors"]
  end

  test "removeEventModerator 先指派再移除：errors 空且库内记录确实消失" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    moderator = Fixtures.register_user_with_email("gql-remove-mod@example.com")
    Fixtures.add_member(workspace, moderator, [:learner])
    event = EventsFixtures.create_event(workspace, owner)

    assert %{"data" => %{"assignEventModerator" => %{"errors" => [], "result" => result}}} =
             graphql(
               assign_mutation(workspace.id, event.id, "gql-remove-mod@example.com"),
               sign_in_token(owner)
             )

    moderator_row_id = result["id"]

    # 前置：记录已在库——防「断言落在空集合上」的假绿（列表含 fixture 自带的
    # owner 主理人，故用存在性断言而非单元素匹配）
    assert {:ok, rows} = Moderators.list(event.id, workspace.id, owner)
    assert Enum.find(rows, &(&1.id == moderator_row_id))

    assert %{"data" => %{"removeEventModerator" => %{"errors" => []}}} =
             graphql(remove_mutation(workspace.id, moderator_row_id), sign_in_token(owner))

    # 副作用断言：直读库（不经 policy），记录确实不在了
    assert {:ok, nil} =
             Ash.get(Cgc2046.Events.EventModerator, moderator_row_id,
               authorize?: false,
               tenant: workspace.id,
               not_found_error?: false
             )
  end

  defp assign_mutation(workspace_id, event_id, anchor) do
    """
    mutation {
      assignEventModerator(workspaceId: "#{workspace_id}", eventId: "#{event_id}", userId: "#{anchor}") {
        result { id userId userDisplayName userMemberNumber }
        errors { message code }
      }
    }
    """
  end

  defp remove_mutation(workspace_id, moderator_id) do
    """
    mutation {
      removeEventModerator(workspaceId: "#{workspace_id}", moderatorId: "#{moderator_id}") {
        result { id }
        errors { message code }
      }
    }
    """
  end

  defp list_query(workspace_id, event_id) do
    """
    query {
      eventModerators(workspaceId: "#{workspace_id}", eventId: "#{event_id}") {
        userId
        userDisplayName
        userMemberNumber
        assignedByDisplayName
        assignedByMemberNumber
      }
    }
    """
  end

  defp expected_member_number(uuid) do
    "CGC-" <> (uuid |> String.replace("-", "") |> String.slice(0, 6) |> String.upcase())
  end

  defp sign_in_token(user) do
    mutation = """
    mutation {
      signIn(login: "#{user.email}", password: "#{Fixtures.password()}") { id }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => mutation})

    assert %{"data" => %{"signIn" => %{"id" => _}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  defp graphql(query, nil) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end

  defp graphql(query, token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end
end
