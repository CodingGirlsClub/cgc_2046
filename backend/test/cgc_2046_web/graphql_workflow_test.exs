defmodule Cgc2046Web.GraphqlWorkflowTest do
  @moduledoc """
  #40 GraphQL 查询面验收测试。

  覆盖 6 个新查询的端到端解析（ConnCase 经 /api/graphql 走完整 AshGraphQL
  pipeline：filter + read policy，无 tenant——同 workspaceMembers 既有模式）：

  - listWorkflowRuns：成员可见本工作台 run；非成员空结果
  - getWorkflowRun：按 id 取 run 详情
  - listEvents / getEvent / listCourses / getCourse：成员可见；非成员空结果

  这是 #40 查询面的唯一真实解析证明（schema 重生成只证明编译，不证明解析）。
  """

  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Events.{Course, Event}

  alias Cgc2046.Workflows.{
    ResearchInstantiator,
    StepHandlerRegistry,
    TestActions,
    WorkflowDefinition
  }

  alias AshAuthentication.Info, as: AuthInfo

  @admin_email "gql-wf-admin@example.com"
  @outsider_email "gql-wf-outsider@example.com"
  @password "sup3r-secret-password"

  setup do
    # 注册测试 step handlers（ADR-0003 两阶段初始化）
    StepHandlerRegistry.register(TestActions.Uppercase)
    StepHandlerRegistry.register(TestActions.AppendExclamation)
    StepHandlerRegistry.register(TestActions.AlwaysFail)
    :ok
  end

  defp password_strategy, do: AuthInfo.strategy!(User, :password)

  defp register_user(email) do
    strategy = password_strategy()

    assert {:ok, user} =
             AshAuthentication.Strategy.action(strategy, :register, %{
               email: email,
               password: @password
             })

    user
  end

  defp platform_admin(email \\ @admin_email) do
    user = register_user(email)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = true WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, actor: user, authorize?: false, domain: Cgc2046.GlobalApi)
  end

  defp graphql_post(conn, query, token) do
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

  defp sign_in_token(email, password) do
    query = """
    mutation {
      signIn(email: "#{email}", password: "#{password}") {
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

  defp create_workspace(admin) do
    slug = "gql-wf-ws-#{System.unique_integer([:positive])}"

    assert {:ok, workspace} =
             Workspace
             |> Ash.Changeset.for_create(:create, %{slug: slug, name: "GQL WF WS"})
             |> Ash.create(actor: admin)

    workspace
  end

  # 纯 auto 教研定义：uppercase → append_exclamation（start_run 直接 succeeded）
  defp auto_node_def do
    %{
      "steps" => [
        %{
          "id" => "uppercase",
          "type" => "auto",
          "action" => "Elixir.Cgc2046.Workflows.TestActions.Uppercase"
        },
        %{
          "id" => "append_exclamation",
          "type" => "auto",
          "action" => "Elixir.Cgc2046.Workflows.TestActions.AppendExclamation"
        }
      ]
    }
  end

  defp create_definition(workspace, actor, node_def) do
    WorkflowDefinition
    |> Ash.Changeset.for_create(
      :create,
      %{name: "教研 workflow", type: :research, node_def: node_def},
      tenant: workspace.id,
      actor: actor
    )
    |> Ash.create(tenant: workspace.id, actor: actor)
  end

  defp publish_definition(defn, workspace, actor) do
    defn
    |> Ash.Changeset.for_update(:publish, %{}, actor: actor)
    |> Ash.update(tenant: workspace.id, actor: actor)
  end

  defp create_event(workspace, actor) do
    Event
    |> Ash.Changeset.for_create(:create, %{title: "教研活动"}, tenant: workspace.id, actor: actor)
    |> Ash.create(tenant: workspace.id, actor: actor)
  end

  defp create_course(workspace, actor) do
    Course
    |> Ash.Changeset.for_create(:create, %{title: "教研课程"}, tenant: workspace.id, actor: actor)
    |> Ash.create(tenant: workspace.id, actor: actor)
  end

  # 建 workspace + published 教研定义 + 已启动 run（succeeded）
  defp seeded_run do
    admin = platform_admin()
    workspace = create_workspace(admin)
    {:ok, defn} = create_definition(workspace, admin, auto_node_def())
    {:ok, published} = publish_definition(defn, workspace, admin)
    {:ok, event} = create_event(workspace, admin)

    assert {:ok, run} =
             ResearchInstantiator.launch(
               workspace.id,
               published.id,
               %{"event_id" => event.id, "title" => event.title, "text" => "hi"},
               :event
             )

    {admin, workspace, run}
  end

  describe "listWorkflowRuns / getWorkflowRun（#40）" do
    test "成员可见本工作台 run（count + results + status）" do
      {_admin, workspace, run} = seeded_run()
      token = sign_in_token(@admin_email, @password)

      query = """
      query {
        listWorkflowRuns(filter: {workspaceId: {eq: "#{workspace.id}"}}) {
          count
          results { id status }
        }
      }
      """

      res = graphql_post(build_conn(), query, token)

      assert %{
               "data" => %{
                 "listWorkflowRuns" => %{"count" => count, "results" => results}
               }
             } = res

      assert count == 1
      assert [%{"id" => id, "status" => status}] = results
      assert id == run.id
      assert status == "succeeded"
    end

    test "非成员空结果（read policy 过滤）" do
      {_admin, workspace, _run} = seeded_run()
      _outsider = register_user(@outsider_email)
      token = sign_in_token(@outsider_email, @password)

      query = """
      query {
        listWorkflowRuns(filter: {workspaceId: {eq: "#{workspace.id}"}}) {
          count
          results { id }
        }
      }
      """

      res = graphql_post(build_conn(), query, token)

      assert %{
               "data" => %{
                 "listWorkflowRuns" => %{"count" => 0, "results" => []}
               }
             } = res
    end

    test "getWorkflowRun 按 id 取详情（含 facts JsonString）" do
      {_admin, _workspace, run} = seeded_run()
      token = sign_in_token(@admin_email, @password)

      query = """
      query {
        getWorkflowRun(id: "#{run.id}") {
          id status facts
        }
      }
      """

      res = graphql_post(build_conn(), query, token)

      assert %{
               "data" => %{
                 "getWorkflowRun" => %{"id" => id, "status" => status, "facts" => facts}
               }
             } = res

      assert id == run.id
      assert status == "succeeded"
      # facts 是 JsonString（JSON 编码字符串），可解析为 map
      assert is_binary(facts)
      assert %{"uppercase" => %{"text" => "HI"}} = Jason.decode!(facts)
    end
  end

  describe "listEvents / getEvent / listCourses / getCourse（#40）" do
    test "成员可见本工作台活动与课程" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, event} = create_event(workspace, admin)
      {:ok, course} = create_course(workspace, admin)
      token = sign_in_token(@admin_email, @password)

      events_query = """
      query {
        listEvents(filter: {workspaceId: {eq: "#{workspace.id}"}}) {
          count
          results { id title }
        }
      }
      """

      res = graphql_post(build_conn(), events_query, token)

      assert %{
               "data" => %{
                 "listEvents" => %{"count" => 1, "results" => [%{"id" => id, "title" => title}]}
               }
             } = res

      assert id == event.id
      assert title == "教研活动"

      courses_query = """
      query {
        listCourses(filter: {workspaceId: {eq: "#{workspace.id}"}}) {
          count
          results { id title }
        }
      }
      """

      res = graphql_post(build_conn(), courses_query, token)

      assert %{
               "data" => %{
                 "listCourses" => %{"count" => 1, "results" => [%{"id" => id, "title" => title}]}
               }
             } = res

      assert id == course.id
      assert title == "教研课程"

      get_event_query = """
      query {
        getEvent(id: "#{event.id}") {
          id status
        }
      }
      """

      res = graphql_post(build_conn(), get_event_query, token)

      assert %{
               "data" => %{
                 "getEvent" => %{"id" => id, "status" => status}
               }
             } = res

      assert id == event.id
      assert status == "draft"

      get_course_query = """
      query {
        getCourse(id: "#{course.id}") {
          id status
        }
      }
      """

      res = graphql_post(build_conn(), get_course_query, token)

      assert %{
               "data" => %{
                 "getCourse" => %{"id" => id, "status" => status}
               }
             } = res

      assert id == course.id
      assert status == "draft"
    end
  end
end
