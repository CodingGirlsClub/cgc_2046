defmodule Cgc2046Web.Plugs.DesktopClientGatePlugTest do
  @moduledoc """
  桌面端版本门控与止损开关 Plug 测试（ADR-0027）。

  覆盖：
  - 单元级（`call/2` 与 `parse_env/1`）
  - 集成级（真实 Router / Endpoint 走 `/api/graphql`、`/v1/models`、`/mcp`、
    `DELETE /mcp/token`、`/healthz`）
  """
  # 切换 Application env(:desktop_client_gate)，不可与其它测试并发
  use Cgc2046Web.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Mcp.Token
  alias Cgc2046Web.Plugs.DesktopClientGatePlug

  @graphql_ping ~s({"query":"{ __typename }"})
  @mcp_init ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"gate-test","version":"0.1.0"}}})

  setup do
    previous = Application.get_env(:cgc_2046, :desktop_client_gate)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:cgc_2046, :desktop_client_gate)
      else
        Application.put_env(:cgc_2046, :desktop_client_gate, previous)
      end
    end)

    :ok
  end

  defp desktop_conn(method, path, version) do
    conn =
      build_conn(method, path)
      |> put_req_header("x-cgc-client", "desktop")
      |> put_req_header("x-cgc-client-platform", "macos-aarch64")

    if version do
      put_req_header(conn, "x-cgc-client-version", version)
    else
      conn
    end
  end

  defp call_plug(conn, opts \\ []) do
    DesktopClientGatePlug.call(conn, DesktopClientGatePlug.init(opts))
  end

  defp issue_mcp_token(user) do
    {:ok, token} =
      Token
      |> Ash.Changeset.for_create(:issue, %{name: "desktop gate test"}, actor: user)
      |> Ash.create()

    {token, token.__metadata__[:plain_token]}
  end

  # ---- parse_env/1 纯函数 ----

  test "parse_env/1：空 env 默认全部关闭" do
    assert DesktopClientGatePlug.parse_env(%{}) == [
             kill_switch: false,
             kill_switch_message: nil,
             min_supported_version: nil,
             blocked_versions: [],
             download_url: "https://github.com/CodingGirlsClub/cgc_2046/releases/latest"
           ]
  end

  test "parse_env/1：解析 kill_switch / 逗号黑名单 / trim 与空字符串忽略" do
    cfg =
      DesktopClientGatePlug.parse_env(%{
        "DESKTOP_KILL_SWITCH" => "true",
        "DESKTOP_KILL_SWITCH_MESSAGE" => "  临时维护中  ",
        "DESKTOP_MIN_SUPPORTED_VERSION" => " 0.1.0-dev.20261125 ",
        "DESKTOP_BLOCKED_VERSIONS" => " 0.1.0-dev.20261120, , 0.2.1 , ",
        "DESKTOP_DOWNLOAD_URL" => "   "
      })

    assert cfg[:kill_switch] == true
    assert cfg[:kill_switch_message] == "临时维护中"
    assert cfg[:min_supported_version] == "0.1.0-dev.20261125"
    assert cfg[:blocked_versions] == ["0.1.0-dev.20261120", "0.2.1"]
    assert cfg[:download_url] == "https://github.com/CodingGirlsClub/cgc_2046/releases/latest"

    cfg_one = DesktopClientGatePlug.parse_env(%{"DESKTOP_KILL_SWITCH" => "1"})
    assert cfg_one[:kill_switch] == true
  end

  # ---- 单元级 call/2 ----

  test "默认未配置：带或不带 desktop 头均放行" do
    Application.delete_env(:cgc_2046, :desktop_client_gate)

    conn_without_header = build_conn(:post, "/api/graphql") |> call_plug()
    refute conn_without_header.halted

    conn_with_header = desktop_conn(:post, "/api/graphql", "0.1.0") |> call_plug()
    refute conn_with_header.halted
  end

  test "非桌面流量（无头 / web / miniprogram）：即使全部开关开启仍放行（非 desktop_only）" do
    Application.put_env(:cgc_2046, :desktop_client_gate,
      kill_switch: true,
      min_supported_version: "9.9.9",
      blocked_versions: ["0.1.0"]
    )

    for client <- [nil, "web", "miniprogram"] do
      conn = build_conn(:post, "/api/graphql")
      conn = if client, do: put_req_header(conn, "x-cgc-client", client), else: conn
      res = call_plug(conn)
      refute res.halted
    end
  end

  test "min_supported_version：SemVer prerelease 与正式版边界" do
    Application.put_env(:cgc_2046, :desktop_client_gate,
      min_supported_version: "0.1.0-dev.20261125",
      download_url: "https://codingirlsclub.com/download"
    )

    rejected = desktop_conn(:post, "/api/graphql", "0.1.0-dev.20261120") |> call_plug()
    assert rejected.halted
    assert rejected.status == 426
    assert [content_type | _] = get_resp_header(rejected, "content-type")
    assert content_type =~ "application/json"

    assert %{
             "error" => %{
               "code" => "client_upgrade_required",
               "message" => message,
               "min_version" => "0.1.0-dev.20261125",
               "download_url" => "https://codingirlsclub.com/download"
             }
           } = Jason.decode!(rejected.resp_body)

    assert is_binary(message) and message != ""

    for allowed <- ["0.1.0-dev.20261125", "0.1.0-dev.20261125.1", "0.1.0"] do
      conn = desktop_conn(:post, "/api/graphql", allowed) |> call_plug()
      refute conn.halted, "expected #{allowed} to be allowed"
    end

    Application.put_env(:cgc_2046, :desktop_client_gate, min_supported_version: "0.2.0")

    rejected_stable = desktop_conn(:post, "/api/graphql", "0.1.0") |> call_plug()
    assert rejected_stable.halted
    assert rejected_stable.status == 426

    allowed_stable = desktop_conn(:post, "/api/graphql", "0.2.0") |> call_plug()
    refute allowed_stable.halted
  end

  test "min_supported_version：desktop 请求缺失或非法版本号 fail-closed 返回 426" do
    Application.put_env(:cgc_2046, :desktop_client_gate, min_supported_version: "0.1.0")

    for bad_version <- [nil, "", "   ", "not-semver"] do
      conn = desktop_conn(:post, "/api/graphql", bad_version) |> call_plug()
      assert conn.halted
      assert conn.status == 426
      assert %{"error" => %{"code" => "client_upgrade_required"}} = Jason.decode!(conn.resp_body)
    end
  end

  test "blocked_versions：精确命中返回 426 client_version_blocked，未命中放行" do
    Application.put_env(:cgc_2046, :desktop_client_gate,
      blocked_versions: ["0.1.0-dev.20261120", "0.2.1"]
    )

    blocked = desktop_conn(:post, "/api/graphql", "0.1.0-dev.20261120") |> call_plug()
    assert blocked.halted
    assert blocked.status == 426
    assert %{"error" => %{"code" => "client_version_blocked"}} = Jason.decode!(blocked.resp_body)

    ok = desktop_conn(:post, "/api/graphql", "0.2.0") |> call_plug()
    refute ok.halted
  end

  test "kill_switch: true 优先级最高，覆盖 blocked_versions 与 min_supported_version" do
    Application.put_env(:cgc_2046, :desktop_client_gate,
      kill_switch: true,
      kill_switch_message: "服务端紧急维护，请稍后重试",
      min_supported_version: "9.9.9",
      blocked_versions: ["0.1.0"]
    )

    conn = desktop_conn(:post, "/api/graphql", "0.1.0") |> call_plug()
    assert conn.halted
    assert conn.status == 426

    assert %{
             "error" => %{
               "code" => "desktop_client_disabled",
               "message" => "服务端紧急维护，请稍后重试",
               "min_version" => "9.9.9",
               "download_url" => "https://github.com/CodingGirlsClub/cgc_2046/releases/latest"
             }
           } = Jason.decode!(conn.resp_body)
  end

  test "异常服务端 min_supported_version 配置：记 warning 且不崩溃或误杀请求" do
    Application.put_env(:cgc_2046, :desktop_client_gate, min_supported_version: "invalid_semver")

    {conn, log} =
      with_log(fn ->
        desktop_conn(:post, "/api/graphql", "0.1.0") |> call_plug()
      end)

    refute conn.halted
    assert log =~ "DESKTOP_MIN_SUPPORTED_VERSION"
  end

  # ---- 集成级（经 Endpoint / Router 全链路） ----

  test "集成：/api/graphql 与 /mcp 按客户端头区分放行与 426 拒绝" do
    Application.put_env(:cgc_2046, :desktop_client_gate, min_supported_version: "0.2.0")

    # 非桌面端放行
    web_graphql =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-cgc-client", "web")
      |> post("/api/graphql", @graphql_ping)

    assert web_graphql.status != 426

    web_mcp =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> post("/mcp", @mcp_init)

    assert web_mcp.status == 401

    # 旧桌面端在 /api/graphql 与 /mcp 均被 426 拦截
    old_graphql =
      desktop_conn(:post, "/api/graphql", "0.1.0")
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", @graphql_ping)

    assert old_graphql.status == 426

    assert %{"error" => %{"code" => "client_upgrade_required"}} =
             Jason.decode!(old_graphql.resp_body)

    old_mcp =
      desktop_conn(:post, "/mcp", "0.1.0")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> post("/mcp", @mcp_init)

    assert old_mcp.status == 426
    assert %{"error" => %{"code" => "client_upgrade_required"}} = Jason.decode!(old_mcp.resp_body)
  end

  test "集成：/v1/*（desktop_only: true）在 kill_switch: true 时连无头旧包也直接 426，关闭后交回 Auth" do
    Application.put_env(:cgc_2046, :desktop_client_gate,
      kill_switch: true,
      min_supported_version: "0.2.0"
    )

    killed = get(build_conn(), "/v1/models")
    assert killed.status == 426
    assert %{"error" => %{"code" => "desktop_client_disabled"}} = Jason.decode!(killed.resp_body)

    Application.put_env(:cgc_2046, :desktop_client_gate,
      kill_switch: false,
      min_supported_version: "0.2.0"
    )

    headless_normal = get(build_conn(), "/v1/models")
    assert headless_normal.status == 401
  end

  test "集成：DELETE /mcp/token 与 GET /healthz 在 kill_switch + 黑名单 + 旧版本下依然豁免放行" do
    user = Fixtures.register_user("desktop-gate-delete-exempt")
    {_token, plain} = issue_mcp_token(user)

    Application.put_env(:cgc_2046, :desktop_client_gate,
      kill_switch: true,
      min_supported_version: "9.9.9",
      blocked_versions: ["0.1.0"]
    )

    del_conn =
      desktop_conn(:delete, "/mcp/token", "0.1.0")
      |> put_req_header("authorization", "Bearer #{plain}")
      |> delete("/mcp/token")

    assert del_conn.status in [200, 204]

    health_conn =
      desktop_conn(:get, "/healthz", "0.1.0")
      |> get("/healthz")

    assert health_conn.status == 200
    assert health_conn.resp_body == "ok"
  end

  test "支持 runtime.exs 注入的原始 env 字符串形态并发送 Telemetry 拒绝事件" do
    test_pid = self()
    handler_id = "desktop-gate-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:cgc_2046, :desktop_gate, :rejected],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Application.put_env(:cgc_2046, :desktop_client_gate,
      kill_switch: "",
      kill_switch_message: "   ",
      min_supported_version: "0.2.0",
      blocked_versions: "0.1.0-dev.1, 0.1.9",
      download_url: ""
    )

    blocked = desktop_conn(:post, "/api/graphql", "0.1.9") |> call_plug()
    assert blocked.halted
    assert blocked.status == 426
    assert %{"error" => %{"code" => "client_version_blocked"}} = Jason.decode!(blocked.resp_body)

    assert_receive {:telemetry, [:cgc_2046, :desktop_gate, :rejected], %{count: 1},
                    %{
                      code: "client_version_blocked",
                      client_version: "0.1.9",
                      client_platform: "macos-aarch64",
                      path: "/api/graphql"
                    }}
  end
end
