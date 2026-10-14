defmodule Cgc2046Web.McpTokenController do
  @moduledoc """
  连接 token 凭自身核实身份与自撤销（ADR-0022，KTD3）：`GET /mcp/token`、`DELETE /mcp/token`。

  CGC 本机 Host 配对时拿学习凭证调 `GET`，取得平台核实的身份——本机确认弹窗只显示这份身份；
  学员拒绝、超时或卸载时调 `DELETE` 撤销它。鉴权是 `:mcp` pipeline 的 Bearer
  （`Cgc2046Web.Plugs.McpAuthPlug`），不认登录态；两个动作都只作用于出示的这枚 token，
  请求里携带的任何 id 一律忽略。撤销其他电脑的凭证走登录态的 `revokeMcpToken(id)`。
  """
  use Cgc2046Web, :controller

  alias Cgc2046.Accounts.PhoneNumber
  alias Cgc2046.Mcp.Token

  def show(conn, _params) do
    user = conn.assigns.current_user

    json(conn, %{
      token_id: conn.assigns.mcp_token_id,
      user_id: user.id,
      kind: conn.assigns.mcp_token_kind,
      display_name: user.display_name,
      masked_identifier: masked_identifier(user)
    })
  end

  def delete(conn, _params) do
    # 鉴权刚核实过这枚 token 有效且属于 current_user；撤销仍失败（如与另一处撤销竞态）即 500，
    # Host 收不到 204 就不会当成已撤销
    {:ok, _revoked} = Token.revoke(conn.assigns.mcp_token_id, conn.assigns.current_user)
    send_resp(conn, 204, "")
  end

  # 弹窗凭它区分同名账号：有邮箱用邮箱，否则用手机号；两者的明文都不出响应
  defp masked_identifier(%{email: email}) when not is_nil(email),
    do: mask_email(to_string(email))

  defp masked_identifier(%{phone: phone}), do: PhoneNumber.mask(phone)

  # 与闪念间找回确认页（Cgc2046.Flashback.Tokens）同一口径：本地部分首字符 + *** + @域名
  defp mask_email(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] when local != "" and domain != "" -> String.first(local) <> "***@" <> domain
      _ -> "***"
    end
  end
end
