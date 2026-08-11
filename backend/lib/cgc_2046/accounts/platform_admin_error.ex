defmodule Cgc2046.Accounts.PlatformAdminError do
  @moduledoc """
  平台管理员操作被拒绝的领域错误（≥1 admin 不变量 / 目标非 admin）。

  由 `User :demote_platform_admin` action 的 change 返回；`code` 即 GraphQL
  错误契约（`last_admin_denied` / `not_platform_admin`），经
  `Cgc2046Web.AshGraphql.PlatformAdminError` 协议映射进响应。
  """
  use Splode.Error, fields: [:message, :code], class: :invalid

  def message(error), do: error.message || "platform admin operation denied"
end

defimpl AshGraphql.Error, for: Cgc2046.Accounts.PlatformAdminError do
  def to_error(error) do
    %{
      message: error.message,
      short_message: error.message,
      code: error.code,
      vars: %{},
      fields: [:is_platform_admin]
    }
  end
end
