defmodule Cgc2046Web.GraphqlEventManagementTest do
  @moduledoc """
  E-11 #127 GraphQL mutation 链路：createEvent → updateEvent（visibility 切换）→
  launchEvent → closeEvent。管理面产品入口（此前活动只能经 AshAdmin 操作）。
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Event
  alias Cgc2046.EventsFixtures, as: EventFixtures

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

  test "open 后经 GraphQL updateEvent 改 slug：errors 带稳定 code event_slug_locked（#619）" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    token = sign_in_token(admin)

    assert %{"data" => %{"createEvent" => %{"result" => created, "errors" => []}}} =
             graphql(
               create_event_mutation(workspace.id, %{
                 title: "slug 锁定测试",
                 enrollment_policy: :open,
                 slug: "gql-slug-lock-open"
               }),
               token
             )

    assert %{"data" => %{"launchEvent" => %{"result" => %{}, "errors" => []}}} =
             graphql(action_mutation("launchEvent", created["id"]), token)

    assert %{"data" => %{"updateEvent" => %{"result" => nil, "errors" => errors}}} =
             graphql(
               """
               mutation {
                 updateEvent(id: "#{created["id"]}", input: {slug: "new-slug"}) {
                   result { id }
                   errors { code message }
                 }
               }
               """,
               token
             )

    # BusinessError 经 AshGraphql.Error 协议透传稳定 code（原裸 add_error 只有
    # invalid_attribute）；Course 同构管线（domain 层已钉），不重复接线断言。
    assert [%{"code" => "event_slug_locked", "message" => message}] = errors
    assert message =~ "slug is locked"

    assert Ash.get!(Event, created["id"], authorize?: false).slug == "gql-slug-lock-open"
  end

  test "offeringReadiness：登录用户可查 GO/NO-GO 清单；匿名拒绝" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin)
    token = sign_in_token(admin)

    query = """
    query {
      offeringReadiness(id: "#{event.id}") {
        ready
        items { key label ok }
      }
    }
    """

    assert %{"data" => %{"offeringReadiness" => %{"ready" => ready, "items" => items}}} =
             graphql(query, token)

    # registration_deadline 默认已设（fixture 7 天后）；curriculum 定义未建 → ready=false
    assert is_boolean(ready)

    # G2：清单三项（registration_deadline / curriculum_definition / sponsorship_tiers_configured）
    assert length(items) == 3

    assert Enum.map(items, & &1["key"]) == [
             "registration_deadline",
             "curriculum_definition",
             "sponsorship_tiers_configured"
           ]

    # 匿名拒绝
    anon =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => query})
      |> json_response(200)

    assert %{"data" => %{"offeringReadiness" => nil}} = anon
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

  test "非成员 PlatformAdmin 不能 createEvent（只读审计）" do
    admin = Fixtures.platform_admin("gql-event-readonly-admin")
    workspace = Fixtures.create_workspace(admin)
    Fixtures.remove_membership(workspace, admin)

    response =
      graphql(
        create_event_mutation(workspace.id, %{title: "只读越权创建", enrollment_policy: :open}),
        sign_in_token(admin)
      )

    assert %{"data" => %{"createEvent" => %{"result" => nil, "errors" => errors}}} = response
    assert errors != []
  end

  # #616：关押金（金额残留）后经 GraphQL 重开、缺 depositAmountCents → 资源级
  # 稳定 code 拒绝。MCP 第一段快速失败只覆盖工具入口；本测试钉住 action 级
  # 校验对 GraphQL 缺键同样生效。
  test "updateEvent 关押金后重开缺金额 → 稳定 code 拒绝" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    token = sign_in_token(admin)
    anchor = EventFixtures.days_from_now(8) |> DateTime.to_iso8601()

    create_response =
      graphql(
        create_event_mutation(workspace.id, %{title: "押金重开", enrollment_policy: :open}),
        token
      )

    assert %{"data" => %{"createEvent" => %{"result" => created, "errors" => []}}} =
             create_response

    update = fn input ->
      graphql(
        """
        mutation {
          updateEvent(id: "#{created["id"]}", input: {#{input}}) {
            result { id depositEnabled depositAmountCents }
            errors { message code }
          }
        }
        """,
        token
      )
    end

    assert %{"data" => %{"updateEvent" => %{"result" => enabled, "errors" => []}}} =
             update.(
               "depositEnabled: true, depositAmountCents: 6900, " <>
                 ~s(endsAt: "#{anchor}", registrationDeadline: "#{anchor}")
             )

    assert enabled["depositEnabled"] == true

    # 手动关押金不带金额键 → 金额列残留（#616 场景土壤）
    assert %{"data" => %{"updateEvent" => %{"result" => disabled, "errors" => []}}} =
             update.("depositEnabled: false")

    assert disabled["depositEnabled"] == false

    # 重开缺金额 → 拒绝，旧金额不得静默复活
    assert %{"data" => %{"updateEvent" => %{"result" => nil, "errors" => [error]}}} =
             update.("depositEnabled: true")

    assert error["code"] == "event_deposit_amount_must_be_explicit"

    # 显式带金额重开 → 通过
    assert %{"data" => %{"updateEvent" => %{"result" => reopened, "errors" => []}}} =
             update.("depositEnabled: true, depositAmountCents: 4200")

    assert reopened["depositAmountCents"] == 4200
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

  defp graphql(query, token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end
end
