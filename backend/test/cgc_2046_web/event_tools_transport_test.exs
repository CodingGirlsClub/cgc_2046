defmodule Cgc2046Web.EventToolsTransportTest do
  @moduledoc """
  `cancel_event` 经真实 `/mcp` streamable HTTP transport 的最小验收：
  首次调用进入确认流，跨工作台 Event ID 坍缩为 not found。
  """

  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Mcp.Token

  @initialize_body ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"event-tools-transport-test","version":"0.0.0"}}})

  defp issue_plain_token(user) do
    {:ok, token} =
      Token
      |> Ash.Changeset.for_create(:issue, %{name: "event tools transport test"}, actor: user)
      |> Ash.create()

    token.__metadata__[:plain_token]
  end

  defp post_mcp(plain_token, body, session_id \\ nil) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{plain_token}")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")

    conn =
      if session_id,
        do: put_req_header(conn, "mcp-session-id", session_id),
        else: conn

    post(conn, "/mcp", body)
  end

  defp open_session(plain_token) do
    conn = post_mcp(plain_token, @initialize_body)

    assert conn.status == 200
    [session_id] = get_resp_header(conn, "mcp-session-id")
    session_id
  end

  defp call_tool(plain_token, session_id, id, name, arguments) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      })

    conn = post_mcp(plain_token, body, session_id)
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  test "cancel_event confirmation and cross-workspace denial use the real MCP transport" do
    %{owner: owner_a, workspace: workspace_a} = Fixtures.workspace_with_member()
    %{owner: owner_b, workspace: workspace_b} = Fixtures.workspace_with_member()
    event_a = EventFixtures.create_event(workspace_a, owner_a)
    event_b = EventFixtures.create_event(workspace_b, owner_b)
    plain_token = issue_plain_token(owner_a)
    session_id = open_session(plain_token)

    confirmation =
      call_tool(plain_token, session_id, 2, "cancel_event", %{
        "workspace_id" => workspace_a.id,
        "event_id" => event_a.id
      })

    assert %{"result" => %{"content" => [%{"text" => text}]}} = confirmation
    assert %{"status" => "needs_confirmation"} = Jason.decode!(text)

    denied =
      call_tool(plain_token, session_id, 3, "cancel_event", %{
        "workspace_id" => workspace_a.id,
        "event_id" => event_b.id
      })

    assert %{"error" => %{"message" => "event not found: " <> _}} = denied
  end
end
