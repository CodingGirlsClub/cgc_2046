defmodule Cgc2046Web.ApiHelpers do
  @moduledoc """
  REST 控制器共享 helper(T05):actor/tenant 提取 + Ash 错误翻译。

  授权判定在资源 policy / action 内(见 spec §4 约定:租户资源 policies 声明 +
  写 action 首行 `Rbac.ensure!`),控制器只负责翻译错误契约状态码
  (docs/spec-平台核心与OpenClacky对接.md §5):越权→403、校验失败→422、其它→400。
  """

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_status: 2]

  @doc "当前认证用户(RequireAuth 保证非 nil)。"
  def actor(conn), do: conn.assigns[:current_user]

  @doc "租户 id(路径参数 workspace_id)。"
  def tenant(conn), do: conn.path_params["workspace_id"]

  @doc "把 params 按白名单取字段并转 atom key(去掉无效 key)。"
  def pick_attrs(params, keys) do
    params
    |> Map.take(keys)
    |> Enum.filter(fn {_k, v} -> not is_nil(v) end)
    |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
  end

  @doc "Ash 结果翻译:ok 走 ok_fun,错误按契约翻译状态码。"
  def handle_ash_result(conn, result, ok_fun) do
    case result do
      {:ok, record} ->
        ok_fun.(record)

      :ok ->
        ok_fun.(nil)

      {:error, %Ash.Error.Forbidden{}} ->
        send_error(conn, 403, "Forbidden")

      {:error, %Ash.Error.Invalid{}} ->
        send_error(conn, 422, "Invalid")

      {:error, error} ->
        send_error(conn, 400, Exception.message(error))
    end
  end

  @doc "Ash record → 可 JSON 编码的 map(只取白名单字段)。"
  def json_record(record, fields) do
    Map.take(record, fields)
  end

  @doc "404 响应(资源不存在或不可见)。"
  def send_not_found(conn) do
    send_error(conn, 404, "Not Found")
  end

  def send_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end
