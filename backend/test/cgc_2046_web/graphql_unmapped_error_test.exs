defmodule Cgc2046Web.GraphqlUnmappedErrorTest do
  @moduledoc """
  #612 未映射 DB 错误端到端：GraphQL mutation 与 MCP 工具**双面**。

  构造方式（issue 验收 ① 的「裸 SQL 制造未声明约束的 violation」）：在测试的
  sandbox 事务内给 `events` 加一条 resource DSL **未声明** 的 CHECK，再用真
  GraphQL `updateEvent` / 真 MCP `update_event` 触发它。ash_postgres 在
  `constraints_to_errors/5` 里找不到匹配的 `check_constraint` 声明 → 回
  `Ecto.ConstraintError` → `Ash.Error.to_ash_error/2` → `UnknownError` 叶子 →
  `Ash.Error.Unknown` 类 → 安全网 `database_error`。

  不污染的论证：

  - 约束在 sandbox 事务内创建，测试结束回滚即消失（PostgreSQL DDL 事务性）；
  - 本模块 `async: false`：ExUnit 会等所有 async 模块跑完才串行跑 sync 模块
    （`ExUnit.Runner.async_loop/4` 的 "Wait for all async modules" 分支），
    故 ALTER TABLE 的 ACCESS EXCLUSIVE 锁无并发争用；
  - 约束名与 poison 值 test-unique（`probe_unmapped_title_check` /
    `probe-unmapped-title`），不与真实约束或其它测试数据重名。
  """

  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Event
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Mcp.Tools.UpdateEvent
  alias Cgc2046.Repo

  @constraint "probe_unmapped_title_check"
  @poison "probe-unmapped-title"
  # 底层细节黑名单：约束名 / 注入值 / 表名 / 列名 / SQL 与 Ecto 原文
  @leak ~r/#{@constraint}|#{@poison}|violates|check constraint|Ecto\.ConstraintError|duplicate key|\bevents\b|\btitle\b/

  setup do
    Repo.query!("ALTER TABLE events ADD CONSTRAINT #{@constraint} CHECK (title <> '#{@poison}')")

    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    event = EventFixtures.create_event(workspace, owner, %{title: "未被污染的标题"})

    %{owner: owner, workspace: workspace, event: event}
  end

  test "GraphQL updateEvent 撞未声明 CHECK → database_error + uuid，且响应不含库内文本", %{
    owner: owner,
    event: event
  } do
    token = sign_in_token(owner)

    assert %{
             "data" => %{
               "updateEvent" => %{"result" => nil, "errors" => [error]}
             }
           } =
             graphql(
               """
               mutation {
                 updateEvent(id: "#{event.id}", input: {title: "#{@poison}"}) {
                   result { id title }
                   errors { message code }
                 }
               }
               """,
               token
             )

    assert error["code"] == "database_error"
    assert error["message"] =~ ~r/^database operation failed \(error id: [0-9a-f-]{36}\)$/
    refute error["message"] =~ @leak

    # 事务整体回滚：脏值不落库
    assert Ash.get!(Event, event.id, authorize?: false).title == "未被污染的标题"
  end

  test "同一 mutation 用正常标题仍成功（约束只在注入值上触发，已知路径零回归）", %{
    owner: owner,
    event: event
  } do
    token = sign_in_token(owner)

    assert %{"data" => %{"updateEvent" => %{"result" => %{"title" => "改过的标题"}, "errors" => []}}} =
             graphql(
               """
               mutation {
                 updateEvent(id: "#{event.id}", input: {title: "改过的标题"}) {
                   result { id title }
                   errors { message code }
                 }
               }
               """,
               token
             )

    assert Ash.get!(Event, event.id, authorize?: false).title == "改过的标题"
  end

  test "MCP update_event（确认后执行段）撞同一约束 → database_error 前缀 + uuid，且不含库内文本",
       %{owner: owner, workspace: workspace, event: event} do
    assert {:error, message} =
             UpdateEvent.execute_confirmed(owner, %{
               "workspace_id" => workspace.id,
               "event_id" => event.id,
               "title" => @poison
             })

    assert message =~ ~r/^database_error: database operation failed \(error id: [0-9a-f-]{36}\)$/
    refute message =~ @leak

    assert Ash.get!(Event, event.id, authorize?: false).title == "未被污染的标题"
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
