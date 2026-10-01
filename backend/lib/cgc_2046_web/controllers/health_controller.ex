defmodule Cgc2046Web.HealthController do
  @moduledoc """
  部署健康检查（Kamal / kamal-proxy 切流探测）。

  刻意无 DB 依赖：DB 不可用时 Phoenix endpoint 依然响应，
  避免数据库抖动误杀就绪探测导致部署回退。

  另回传 `x-cgc-version: <KAMAL_VERSION>`（Kamal 注入，形如 `<sha>-pb<hash>`），
  供小程序上传门（`miniprogram/scripts/check-release-schema.mjs`，#786）读出线上实际
  部署的版本；env 不存在（本地 / 非 Kamal 启动）时不加头，门会 fail-closed。
  """
  use Cgc2046Web, :controller

  def show(conn, _params) do
    conn =
      case System.get_env("KAMAL_VERSION") do
        nil -> conn
        version -> put_resp_header(conn, "x-cgc-version", version)
      end

    send_resp(conn, 200, "ok")
  end
end
