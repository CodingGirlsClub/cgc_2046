defmodule Cgc2046Web.HealthControllerTest do
  @moduledoc """
  /healthz 的 `x-cgc-version` 头（#786）：小程序上传门（`miniprogram/scripts/check-release-schema.mjs`）
  靠它读出线上实际部署的 SHA。env 不存在时不加头，门会 fail-closed。
  """

  # 改进程级 env，不能与其他用例并行
  use Cgc2046Web.ConnCase, async: false

  setup do
    previous = System.get_env("KAMAL_VERSION")

    on_exit(fn ->
      if previous,
        do: System.put_env("KAMAL_VERSION", previous),
        else: System.delete_env("KAMAL_VERSION")
    end)
  end

  test "KAMAL_VERSION 存在时回传 x-cgc-version，body 与状态码不变", %{conn: conn} do
    System.put_env("KAMAL_VERSION", "0a6a3d7b-pbdeadbeef")

    conn = get(conn, "/healthz")

    assert response(conn, 200) == "ok"
    assert get_resp_header(conn, "x-cgc-version") == ["0a6a3d7b-pbdeadbeef"]
  end

  test "KAMAL_VERSION 不存在时不加头，body 与状态码不变", %{conn: conn} do
    System.delete_env("KAMAL_VERSION")

    conn = get(conn, "/healthz")

    assert response(conn, 200) == "ok"
    assert get_resp_header(conn, "x-cgc-version") == []
  end
end
