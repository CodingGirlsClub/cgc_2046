defmodule Cgc2046Web.Plugs.DesktopClientGatePlugTest do
  @moduledoc """
  桌面客户端版本门控与止损开关测试（ADR-0027）：
  覆盖 `DesktopRelease.parse_env/1`、`:graphql` / `:mcp` / `:llm_gateway` 管线拦截、
  `DELETE /mcp/token` 豁免、非桌面端放行以及 telemetry 上报。
  """

  use Cgc2046Web.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Cgc2046Web.DesktopRelease

  @endpoint_graphql "/api/graphql"
  @sample_query ~s({"query":"{ __typename }"})

  setup do
    previous = Application.get_env(:cgc_2046, :desktop_release)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:cgc_2046, :desktop_release)
      else
        Application.put_env(:cgc_2046, :desktop_release, previous)
      end
    end)

    Application.delete_env(:cgc_2046, :desktop_release)
    :ok
  end

  defp desktop_conn(version, platform \\ "macos-aarch64") do
    conn =
      build_conn()
      |> put_req_header("x-cgc-client", "desktop")
      |> put_req_header("x-cgc-client-platform", platform)

    if version do
      put_req_header(conn, "x-cgc-client-version", version)
    else
      conn
    end
  end

  describe "DesktopRelease.parse_env/1" do
    test "空白裁剪、布尔开关、blocked_versions 去重与默认 download_url" do
      assert DesktopRelease.parse_env(%{}) == [
               kill_switch: false,
               kill_switch_message: nil,
               min_supported_version: nil,
               blocked_versions: [],
               latest_version: nil,
               download_url: "https://github.com/CodingGirlsClub/cgc_2046/releases/latest",
               release_notes: nil
             ]

      parsed =
        DesktopRelease.parse_env(%{
          "DESKTOP_KILL_SWITCH" => " 1 ",
          "DESKTOP_KILL_SWITCH_MESSAGE" => "  临时维护中  ",
          "DESKTOP_MIN_SUPPORTED_VERSION" => " 0.2.0 ",
          "DESKTOP_BLOCKED_VERSIONS" => "0.1.0, 0.1.1 , 0.1.0, ",
          "DESKTOP_LATEST_VERSION" => " 0.3.0 ",
          "DESKTOP_DOWNLOAD_URL" => " https://codingirlsclub.com/download ",
          "DESKTOP_RELEASE_NOTES" => "  修复崩溃  "
        })

      assert parsed == [
               kill_switch: true,
               kill_switch_message: "临时维护中",
               min_supported_version: "0.2.0",
               blocked_versions: ["0.1.0", "0.1.1"],
               latest_version: "0.3.0",
               download_url: "https://codingirlsclub.com/download",
               release_notes: "修复崩溃"
             ]

      for falsey <- ["false", "0", "", "   ", "yes", nil] do
        assert Keyword.fetch!(
                 DesktopRelease.parse_env(%{"DESKTOP_KILL_SWITCH" => falsey}),
                 :kill_switch
               ) == false
      end

      assert Keyword.fetch!(
               DesktopRelease.parse_env(%{"DESKTOP_KILL_SWITCH" => "true"}),
               :kill_switch
             ) == true
    end
  end

  describe "默认与非桌面请求放行" do
    test "未配置环境变量时桌面请求不被门控拦截" do
      conn =
        desktop_conn("0.1.0")
        |> put_req_header("content-type", "application/json")
        |> post(@endpoint_graphql, @sample_query)

      refute conn.status == 426
    end

    test "无 x-cgc-client 或非 desktop 时，即使全开门控也绝不拦截 :graphql 和 :mcp" do
      Application.put_env(:cgc_2046, :desktop_release,
        kill_switch: true,
        min_supported_version: "9.9.9",
        blocked_versions: ["0.1.0"]
      )

      for client_headers <- [
            [],
            [{"x-cgc-client", "web"}],
            [{"x-cgc-client", "desktop"}, {"x-cgc-client", "desktop"}]
          ] do
        gql_conn =
          Enum.reduce(client_headers, build_conn(), fn {k, v}, acc ->
            %{acc | req_headers: [{k, v} | acc.req_headers]}
          end)
          |> put_req_header("x-cgc-client-version", "0.1.0")
          |> put_req_header("content-type", "application/json")
          |> post(@endpoint_graphql, @sample_query)

        refute gql_conn.status == 426

        mcp_conn =
          Enum.reduce(client_headers, build_conn(), fn {k, v}, acc ->
            %{acc | req_headers: [{k, v} | acc.req_headers]}
          end)
          |> put_req_header("x-cgc-client-version", "0.1.0")
          |> get("/mcp/token")

        refute mcp_conn.status == 426
      end
    end

    test ":llm_gateway (desktop_only: true) 仅在 kill_switch 开启时连无头旧包一并阻断" do
      Application.put_env(:cgc_2046, :desktop_release,
        kill_switch: false,
        min_supported_version: "9.9.9"
      )

      no_header_allowed = get(build_conn(), "/v1/models")
      assert no_header_allowed.status == 401

      Application.put_env(:cgc_2046, :desktop_release,
        kill_switch: true,
        kill_switch_message: "网关维护中"
      )

      blocked = post(build_conn(), "/v1/chat/completions", %{})
      body = json_response(blocked, 426)
      assert body["error"]["code"] == "desktop_client_disabled"
      assert body["error"]["message"] == "网关维护中"
    end
  end

  describe "kill_switch / blocked_versions / min_supported_version 拦截" do
    test "kill_switch 返回 426 desktop_client_disabled，优先于鉴权与其它规则" do
      Application.put_env(:cgc_2046, :desktop_release,
        kill_switch: true,
        kill_switch_message: "紧急停服升级",
        min_supported_version: "9.0.0",
        blocked_versions: ["0.1.0"],
        latest_version: "0.2.0",
        download_url: "https://codingirlsclub.com/releases"
      )

      conn =
        desktop_conn("0.1.0")
        |> put_req_header("content-type", "application/json")
        |> post(@endpoint_graphql, @sample_query)

      body = json_response(conn, 426)

      assert body == %{
               "error" => %{
                 "code" => "desktop_client_disabled",
                 "message" => "紧急停服升级",
                 "min_version" => "9.0.0",
                 "latest_version" => "0.2.0",
                 "download_url" => "https://codingirlsclub.com/releases"
               }
             }

      # kill_switch 无自定义文案时走默认提示
      Application.put_env(:cgc_2046, :desktop_release, kill_switch: true)

      default_conn =
        desktop_conn("9.9.9")
        |> put_req_header("content-type", "application/json")
        |> post(@endpoint_graphql, @sample_query)

      default_body = json_response(default_conn, 426)
      assert default_body["error"]["code"] == "desktop_client_disabled"
      assert default_body["error"]["message"] != ""
    end

    test "blocked_versions 精确匹配返回 426 client_version_blocked" do
      Application.put_env(:cgc_2046, :desktop_release,
        blocked_versions: ["0.1.2-dev.1", "0.1.3"],
        min_supported_version: "0.1.0"
      )

      blocked =
        desktop_conn("0.1.2-dev.1")
        |> put_req_header("content-type", "application/json")
        |> post(@endpoint_graphql, @sample_query)

      body = json_response(blocked, 426)
      assert body["error"]["code"] == "client_version_blocked"

      allowed =
        desktop_conn("0.1.4")
        |> put_req_header("content-type", "application/json")
        |> post(@endpoint_graphql, @sample_query)

      refute allowed.status == 426
    end

    test "min_supported_version 按 SemVer（含 prerelease）拦截旧版并放行新/同版" do
      Application.put_env(:cgc_2046, :desktop_release,
        min_supported_version: "0.1.0",
        latest_version: "0.2.0",
        download_url: "https://codingirlsclub.com/download"
      )

      for outdated <- ["0.0.9", "0.1.0-dev.20261121.1", nil, "not-a-semver"] do
        conn =
          desktop_conn(outdated)
          |> put_req_header("content-type", "application/json")
          |> post(@endpoint_graphql, @sample_query)

        body = json_response(conn, 426)
        assert body["error"]["code"] == "client_upgrade_required"
        assert body["error"]["min_version"] == "0.1.0"
        assert body["error"]["latest_version"] == "0.2.0"
        assert body["error"]["download_url"] == "https://codingirlsclub.com/download"
      end

      for current_or_newer <- ["0.1.0", "0.1.1-rc.1", "0.2.0"] do
        conn =
          desktop_conn(current_or_newer)
          |> put_req_header("content-type", "application/json")
          |> post(@endpoint_graphql, @sample_query)

        refute conn.status == 426
      end
    end

    test "min_supported_version 配置非法时 fail-open 并记录告警" do
      Application.put_env(:cgc_2046, :desktop_release, min_supported_version: "bad-semver")

      log =
        capture_log(fn ->
          conn =
            desktop_conn("0.1.0")
            |> put_req_header("content-type", "application/json")
            |> post(@endpoint_graphql, @sample_query)

          refute conn.status == 426
        end)

      assert log =~ "DESKTOP_MIN_SUPPORTED_VERSION"
    end
  end

  describe "MCP 管线豁免与 telemetry" do
    test "DELETE /mcp/token 在门控激活时豁免（仍可撤销凭据），GET /mcp/token 与 POST /mcp 返回 426" do
      Application.put_env(:cgc_2046, :desktop_release,
        kill_switch: true,
        min_supported_version: "9.0.0"
      )

      delete_conn = delete(desktop_conn("0.1.0"), "/mcp/token")
      # 未带 bearer token 进入 McpAuthPlug 返回 401，未被 426 阻断
      assert delete_conn.status == 401

      get_conn = get(desktop_conn("0.1.0"), "/mcp/token")
      assert get_conn.status == 426

      post_mcp_conn =
        desktop_conn("0.1.0")
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", "{}")

      assert post_mcp_conn.status == 426
    end

    test "拒绝时上报 telemetry 事件 [:cgc_2046, :desktop_gate, :rejected]" do
      handler_id = "desktop-gate-test-#{System.unique_integer([:positive])}"
      parent = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:cgc_2046, :desktop_gate, :rejected],
          fn event, measurements, metadata, _ ->
            send(parent, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Application.put_env(:cgc_2046, :desktop_release, min_supported_version: "0.2.0")

      conn =
        desktop_conn("0.1.0", "windows-x86_64")
        |> put_req_header("content-type", "application/json")
        |> post(@endpoint_graphql, @sample_query)

      assert conn.status == 426

      assert_receive {:telemetry, [:cgc_2046, :desktop_gate, :rejected], %{count: 1}, metadata}
      assert metadata.code == "client_upgrade_required"
      assert metadata.client_version == "0.1.0"
      assert metadata.client_platform == "windows-x86_64"
      assert metadata.path == @endpoint_graphql
    end
  end
end
