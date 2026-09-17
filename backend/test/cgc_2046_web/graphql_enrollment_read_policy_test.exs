defmodule Cgc2046Web.GraphqlEnrollmentReadPolicyTest do
  @moduledoc """
  #547：Enrollment read policy 的 Owner/Admin 分支为 FilterCheck 行级过滤
  （`ActorManagesEnrollmentWorkspace`）——客户端 `or` filter 组合无法扩大
  返回行集。

  fail-closed 判据（全部用例共用）：返回行的 workspace_id ∈ {actor 为
  Owner/Admin 的 workspace} ∪ {actor 本人的报名}。

  同款 SimpleCheck 布尔放行的跨租户复现（修复前）见 issue #547；同族其余
  资源缺口见 #705-#709。
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures

  test "or filter 组合（workspaceId ∪ userId）不能越出 actor 管理的 workspace" do
    setup = cross_tenant_setup()

    query = """
    query {
      enrollments(
        first: 50
        filter: {or: [{workspaceId: {eq: "#{setup.ws_x.id}"}}, {userId: {eq: "#{setup.victim.id}"}}]}
      ) {
        results { id workspaceId userId }
      }
    }
    """

    assert %{"data" => %{"enrollments" => %{"results" => rows}}} =
             graphql(query, setup.owner_token)

    # 集合断言（fail-closed）：可见行只允许 ws_x（owner 管理面）——victim 在
    # ws_y 的报名行、以及任何非 ws_x 行都不得出现
    assert rows != []
    assert Enum.all?(rows, &(&1["workspaceId"] == setup.ws_x.id))
    refute Enum.any?(rows, &(&1["id"] == setup.victim_row_id))
  end

  test "匿名查询 enrollments Forbidden（无 actor）" do
    setup = cross_tenant_setup()

    query = """
    query {
      enrollments(first: 10, filter: {workspaceId: {eq: "#{setup.ws_x.id}"}}) {
        results { id }
      }
    }
    """

    # 匿名：read policy 三分支全部不满足（strict 阶段恒假可判定）→ Forbidden，
    # 不泄露存在性
    assert %{"data" => %{"enrollments" => nil}, "errors" => [error | _]} = graphql(query, nil)
    assert error["code"] == "forbidden"
  end

  test "普通成员（无管理角色）经 or filter 也读不到他人行" do
    setup = cross_tenant_setup()

    query = """
    query {
      enrollments(
        first: 50
        filter: {or: [{workspaceId: {eq: "#{setup.ws_x.id}"}}, {userId: {eq: "#{setup.victim.id}"}}]}
      ) {
        results { id workspaceId userId }
      }
    }
    """

    assert %{"data" => %{"enrollments" => %{"results" => rows}}} =
             graphql(query, setup.member_token)

    # member 只是 ws_x 普通成员（无 manage 角色）：管理分支不放行，
    # 剩本人分支——只能看到自己的报名行
    assert rows != []
    assert Enum.all?(rows, &(&1["userId"] == setup.member.id))
    assert Enum.all?(rows, &(&1["workspaceId"] == setup.ws_x.id))
  end

  test "Owner 带 workspaceId 查询见本 workspace 全部报名（管理面正例）" do
    setup = cross_tenant_setup()

    query = """
    query {
      enrollments(first: 50, filter: {workspaceId: {eq: "#{setup.ws_x.id}"}}) {
        results { id workspaceId userId }
      }
    }
    """

    assert %{"data" => %{"enrollments" => %{"results" => rows}}} =
             graphql(query, setup.owner_token)

    assert Enum.all?(rows, &(&1["workspaceId"] == setup.ws_x.id))
    # member 的行（非 owner 本人）也在管理面内
    assert Enum.any?(rows, &(&1["userId"] == setup.member.id))
  end

  test "Owner 无 workspaceId 的 eventId+status 查询见本 workspace 全部（fetchPendingCount 修复对照）" do
    setup = cross_tenant_setup()

    # 修复前：SimpleCheck 在无 workspaceId 可提取时 match? false，branch1 收窄
    # 为「只见自己」→ Owner 计数只含本人行；修复后：exists 管理分支行级放行
    query = """
    query {
      enrollments(
        first: 50
        filter: {eventId: {eq: "#{setup.event_x.id}"}, status: {eq: "pending"}}
      ) {
        count
        results { id workspaceId userId }
      }
    }
    """

    # count（fetchPendingCount 的真实消费字段）与 results 走同一已授权查询
    assert %{"data" => %{"enrollments" => %{"count" => count, "results" => rows}}} =
             graphql(query, setup.owner_token)

    user_ids = Enum.map(rows, & &1["userId"])
    assert setup.member.id in user_ids
    assert Enum.all?(rows, &(&1["workspaceId"] == setup.ws_x.id))
    assert count == length(rows)
  end

  test "本人 userId 查询照常（branch1 回归）" do
    setup = cross_tenant_setup()

    query = """
    query {
      enrollments(first: 50, filter: {userId: {eq: "#{setup.victim.id}"}}) {
        results { id workspaceId userId }
      }
    }
    """

    assert %{"data" => %{"enrollments" => %{"results" => rows}}} =
             graphql(query, setup.victim_token)

    assert rows != []
    assert Enum.all?(rows, &(&1["userId"] == setup.victim.id))
    # victim 只报了 ws_y 的活动（无管理面）：行集即本人在 ws_y 的报名
    assert Enum.all?(rows, &(&1["workspaceId"] == setup.ws_y.id))
  end

  # ── 布景 ─────────────────────────────────────────────────────────────
  #
  # ws_x：owner（Owner）+ member（普通成员，无 manage 角色）各有一条报名；
  # ws_y：victim（与 owner/member 无关）有一条报名。event_x/event_y 分别
  # 属于两 workspace（enrollment_policy: :request → pending，便于计数对照）。

  defp cross_tenant_setup do
    platform_admin = Fixtures.platform_admin("rp547-platform")
    victim = Fixtures.register_user("rp547-victim")

    # owner（Owner 角色）+ member（:learner——非零、非管理角色：钉住
    # manage_roles 的角色精度，把 :learner 误扩进管理集的变异在此变红）
    # 的 ws_x 组合复用支配模式 fixture；ws_y 是 victim 的隔离租户
    %{owner: owner, workspace: ws_x, member: member} =
      Fixtures.workspace_with_member(member_roles: [:learner])

    ws_y = Fixtures.create_workspace(platform_admin, %{name: "RP547 Y"})

    event_x = EventFixtures.create_event(ws_x, owner, %{enrollment_policy: :request})
    event_y = EventFixtures.create_event(ws_y, platform_admin, %{enrollment_policy: :request})

    {:ok, _} = enroll_on(event_x, owner)
    {:ok, _} = enroll_on(event_x, member)
    {:ok, victim_row} = enroll_on(event_y, victim)

    %{
      ws_x: ws_x,
      ws_y: ws_y,
      event_x: event_x,
      member: member,
      victim: victim,
      victim_row_id: victim_row.id,
      owner_token: sign_in_token(owner),
      member_token: sign_in_token(member),
      victim_token: sign_in_token(victim)
    }
  end

  defp enroll_on(event, user) do
    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, %{event_id: event.id, user_id: user.id})
    |> Ash.create(tenant: event.workspace_id, actor: user)
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

  # 匿名请求不带 Authorization 头（与 graphql_enrollment_my_query_test 同款）——
  # 「无 actor」用例不得走「畸形凭证」路径
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
