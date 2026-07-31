defmodule Cgc2046.Accounts.Token do
  @moduledoc """
  认证 token 存储(ash_authentication TokenResource)。

  白名单模式(`store_all_tokens?` + `require_token_presence_for_authentication?`)
  下,平台签发的每个 JWT 都会在此落一条记录;请求认证时 token 必须在此
  存在才视为有效(比黑名单更强)。撤销 = 删除/标记该记录。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.TokenResource],
    domain: Cgc2046.GlobalApi

  postgres do
    table "tokens"
    repo Cgc2046.Repo
  end
end
