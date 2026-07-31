defmodule Cgc2046Web.AuthPlug do
  @moduledoc """
  认证 plug 集合(ash_authentication 生成)。

  提供 `load_from_bearer/2`:`Authorization: Bearer <token>` 验证(JWT 签名
  校验 + 白名单模式 token 存在性检查),成功时把当前用户放入
  `conn.assigns[:current_user]`,失败则不动 assigns(由 RequireAuth 兜底 401)。

  注:白名单模式(`require_token_presence_for_authentication? true`)下,
  已撤销的 token 在 Token 资源中已不存在,验证自动失败 —— 即"撤销即时
  全局失效"(验收标准 3)。
  """

  use AshAuthentication.Plug, otp_app: :cgc_2046
end
