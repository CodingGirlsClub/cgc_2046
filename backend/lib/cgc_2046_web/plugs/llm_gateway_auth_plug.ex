defmodule Cgc2046Web.Plugs.LlmGatewayAuthPlug do
  @moduledoc """
  `/v1/chat/completions` 的第一方桌面端 scope 门。

  `load_from_bearer` 已校验登录 JWT 并加载用户；本 plug 再校验签发自
  `signInForDesktop` 的 `platform=desktop` claim。Web / 小程序会话 token 即使
  有效也不能调用算力网关，避免把不同端的登录面混成同一个 API 权限。

  失败时清空 `current_user`，由 `LlmGatewayController` 统一返回 401；
  `load_actor` 随后不会再为无效 scope 设置 actor。
  """

  @behaviour Plug

  import Plug.Conn

  alias AshAuthentication.Jwt.Config

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case bearer_token(conn) do
      nil ->
        conn

      token ->
        signer = Config.token_signer(Cgc2046.Accounts.User, [], %{})

        case Joken.verify(token, signer) do
          {:ok, %{"platform" => "desktop"}} ->
            conn

          _ ->
            assign(conn, :current_user, nil)
        end
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      [<<"Bearer ", token::binary>>] when byte_size(token) > 0 -> token
      _ -> nil
    end
  end
end
