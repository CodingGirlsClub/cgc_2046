defmodule Cgc2046Web.AuditMiddleware do
  @moduledoc """
  审计中间件(T05,spec §11):**每次 API 请求(成功或失败)落一条审计记录**。

  挂载策略:放在管道最前面(auth/业务 plug 之前),用 `register_before_send`
  注册回调,在响应发送前执行 —— 因此即使后续 401/403 直接 halt,审计仍会写入
  (spec 要求"成功或失败"都落记录)。

  记录字段(见 `Cgc2046.Audit.AuditLog`):
  - actor_id:从 `conn.assigns[:current_user]`(401 时 nil)
  - client:请求头 `X-CGC-Client`
  - action:method + path(REST)或 `graphql:<operationName>`
  - resource:资源名(REST 路径段或 graphql)
  - workspace_id:从路径参数尽力而为(可空,全局操作如登录失败无 workspace)
  - ip:remote_ip
  - result:HTTP 状态码字符串(如 "200" / "403")

  审计写入失败**绝不**影响业务响应(rescue 吞异常 + 错误也吞)。
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      write_audit(conn)
      conn
    end)
  end

  defp write_audit(conn) do
    actor = conn.assigns[:current_user]

    attrs = %{
      actor_id: actor && actor.id,
      client: get_req_header(conn, "x-cgc-client") |> List.first(),
      action: action_name(conn),
      resource: resource_name(conn),
      workspace_id: workspace_id(conn),
      ip: client_ip(conn),
      result: to_string(conn.status || 200)
    }

    case Ash.create(Cgc2046.Audit.AuditLog, attrs,
           authorize?: false,
           domain: Cgc2046.GlobalApi
         ) do
      {:ok, _audit} -> :ok
      {:error, _error} -> :ok
    end
  rescue
    _ -> :ok
  end

  defp action_name(%{path_info: ["api", "graphql" | _]} = conn) do
    operation = get_in(conn.body_params, ["operationName"]) || "anonymous"

    "graphql:#{operation}"
  end

  defp action_name(conn) do
    "#{conn.method} #{conn.request_path}"
  end

  defp resource_name(%{path_info: ["api", "graphql" | _]}), do: "graphql"

  defp resource_name(conn) do
    conn.path_info
    |> Enum.reject(&(&1 in ["api", "v1"]))
    |> List.first()
  end

  defp workspace_id(conn) do
    conn.path_params["workspace_id"] || conn.assigns[:workspace_id]
  end

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [first | _] -> first |> String.split(",") |> List.first() |> String.trim()
      _ -> conn.remote_ip |> Tuple.to_list() |> Enum.join(".")
    end
  end
end
