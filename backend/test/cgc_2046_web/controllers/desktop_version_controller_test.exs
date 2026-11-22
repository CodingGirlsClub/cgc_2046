defmodule Cgc2046Web.DesktopVersionControllerTest do
  @moduledoc """
  `GET /api/desktop/version` 测试（ADR-0027）：
  验证免鉴权 / 零 DB、no-store 响应头、非强制更新提示、以及在 min_supported_version /
  blocked_versions / kill_switch 激活时仍返回 200 结构化状态供桌面端展示。
  """

  use Cgc2046Web.ConnCase, async: false

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

  test "未配置环境变量时返回 200 且无更新/无强升" do
    conn =
      build_conn()
      |> put_req_header("x-cgc-client", "desktop")
      |> put_req_header("x-cgc-client-version", "0.1.0")
      |> get("/api/desktop/version")

    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert json_response(conn, 200) == %{
             "latest_version" => nil,
             "min_supported_version" => nil,
             "download_url" => "https://github.com/CodingGirlsClub/cgc_2046/releases/latest",
             "release_notes" => nil,
             "kill_switch" => false,
             "update_available" => false,
             "upgrade_required" => false,
             "code" => nil,
             "message" => nil
           }
  end

  test "latest_version 高于客户端版本时提示非强制更新（支持 header、query param 与 prerelease）" do
    Application.put_env(:cgc_2046, :desktop_release,
      latest_version: "0.2.0",
      min_supported_version: "0.1.0-dev.1",
      download_url: "https://codingirlsclub.com/releases",
      release_notes: "支持轻量启动版本检查"
    )

    # 通过 header 查询（0.1.0 < 0.2.0）
    header_conn =
      build_conn()
      |> put_req_header("x-cgc-client-version", "0.1.0")
      |> get("/api/desktop/version")

    assert json_response(header_conn, 200) == %{
             "latest_version" => "0.2.0",
             "min_supported_version" => "0.1.0-dev.1",
             "download_url" => "https://codingirlsclub.com/releases",
             "release_notes" => "支持轻量启动版本检查",
             "kill_switch" => false,
             "update_available" => true,
             "upgrade_required" => false,
             "code" => nil,
             "message" => nil
           }

    # 通过 query param 查询（prerelease 0.2.0-dev.1 < 0.2.0）
    param_conn = get(build_conn(), "/api/desktop/version?version=0.2.0-dev.1")
    assert json_response(param_conn, 200)["update_available"] == true

    # 已是最新或更高版本
    for current <- ["0.2.0", "0.3.0"] do
      conn =
        build_conn()
        |> put_req_header("x-cgc-client-version", current)
        |> get("/api/desktop/version")

      body = json_response(conn, 200)
      assert body["update_available"] == false
      assert body["upgrade_required"] == false
    end
  end

  test "版本低于 min_supported_version 时返回 200 upgrade_required: true，不被 426 阻断" do
    Application.put_env(:cgc_2046, :desktop_release,
      latest_version: "0.3.0",
      min_supported_version: "0.2.0",
      download_url: "https://codingirlsclub.com/download"
    )

    conn =
      build_conn()
      |> put_req_header("x-cgc-client", "desktop")
      |> put_req_header("x-cgc-client-version", "0.1.0")
      |> get("/api/desktop/version")

    body = json_response(conn, 200)
    assert body["upgrade_required"] == true
    assert body["update_available"] == true
    assert body["code"] == "client_upgrade_required"
    assert body["min_supported_version"] == "0.2.0"
    assert body["download_url"] == "https://codingirlsclub.com/download"
    assert is_binary(body["message"]) and body["message"] != ""
  end

  test "kill_switch 或 blocked_versions 命中时返回 200 upgrade_required: true" do
    Application.put_env(:cgc_2046, :desktop_release,
      kill_switch: true,
      kill_switch_message: "系统维护，请稍后重试",
      latest_version: "0.2.0"
    )

    ks_conn =
      build_conn()
      |> put_req_header("x-cgc-client", "desktop")
      |> put_req_header("x-cgc-client-version", "0.2.0")
      |> get("/api/desktop/version")

    ks_body = json_response(ks_conn, 200)
    assert ks_body["upgrade_required"] == true
    assert ks_body["kill_switch"] == true
    assert ks_body["code"] == "desktop_client_disabled"
    assert ks_body["message"] == "系统维护，请稍后重试"

    Application.put_env(:cgc_2046, :desktop_release,
      blocked_versions: ["0.1.5"],
      latest_version: "0.2.0"
    )

    blocked_conn =
      build_conn()
      |> put_req_header("x-cgc-client-version", "0.1.5")
      |> get("/api/desktop/version")

    blocked_body = json_response(blocked_conn, 200)
    assert blocked_body["upgrade_required"] == true
    assert blocked_body["kill_switch"] == false
    assert blocked_body["code"] == "client_version_blocked"
  end
end
