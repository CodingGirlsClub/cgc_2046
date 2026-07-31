defmodule Cgc2046Web.ApiTokenAuth do
  @moduledoc """
  ApiToken 认证 plug(T07,spec §3):在 JWT 会话认证(`load_from_bearer`)失败后,
  尝试以 **ApiToken 机器凭证** 认证 —— `Authorization: Bearer <plain_token>`。

  流程(每请求白名单校验,撤销/过期即时全局失效):
  1. 取 Bearer 明文 → SHA-256 hash
  2. 查 ApiToken 表:`token_hash` 匹配 且 `revoked_at is nil` 且 `expires_at > now`
  3. 命中 → 加载 user,设置 `conn.assigns[:current_user]` 与
     `conn.assigns[:api_token]`(含 scopes/workspace_id,供 /me 使用)
  4. **workspace 绑定校验**:若请求路径含 `workspace_id` 且与 token 绑定的
     workspace 不一致 → 403(验收点 4;一致或 /me 等无 workspace 路径的请求放行)

  未命中(不存在/撤销/过期)不动 assigns,由 RequireAuth 兜底 401。
  """

  import Plug.Conn

  import Ash.Query, only: [filter: 2]

  @behaviour Plug

  alias Cgc2046.Workspaces.ApiToken

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      case authenticate(conn) do
        {:ok, user, api_token} ->
          conn
          |> assign(:current_user, user)
          |> assign(:api_token, api_token)
          |> check_workspace_binding(api_token)

        :error ->
          conn
      end
    end
  end

  defp authenticate(conn) do
    with ["Bearer " <> plain] <- get_req_header(conn, "authorization"),
         %ApiToken{} = api_token <- find_valid_token(plain),
         {:ok, user} <- load_user(api_token.user_id) do
      {:ok, user, api_token}
    else
      _ -> :error
    end
  end

  defp find_valid_token(plain_token) do
    hash = ApiToken.hash_token(plain_token)
    now = DateTime.utc_now()

    case ApiToken
         |> filter(token_hash == ^hash and is_nil(revoked_at) and expires_at > ^now)
         |> Ash.read_one(authorize?: false) do
      {:ok, %ApiToken{} = api_token} -> api_token
      _ -> nil
    end
  end

  defp load_user(user_id) do
    Cgc2046.Accounts.User
    |> Ash.get(user_id, authorize?: false)
  end

  defp check_workspace_binding(conn, api_token) do
    case conn.path_params["workspace_id"] do
      target when is_binary(target) and target != api_token.workspace_id ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(403, Jason.encode!(%{error: "Forbidden: token bound to a different workspace"}))
        |> halt()

      _ ->
        conn
    end
  end
end
