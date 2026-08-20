defmodule Cgc2046Web.HealthController do
  @moduledoc """
  部署健康检查（Kamal / kamal-proxy 切流探测）。

  刻意无 DB 依赖：DB 不可用时 Phoenix endpoint 依然响应，
  避免数据库抖动误杀就绪探测导致部署回退。
  """
  use Cgc2046Web, :controller

  def show(conn, _params) do
    send_resp(conn, 200, "ok")
  end
end
