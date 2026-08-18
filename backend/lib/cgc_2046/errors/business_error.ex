defmodule Cgc2046.Errors.BusinessError do
  @moduledoc """
  领域业务错误（GraphQL 稳定 code 契约，i18n Phase 0）。

  `code` 形如 `<resource>_<reason>`（snake_case，如 `enrollment_already_processed`），
  经 `Cgc2046Web.AshGraphql.BusinessError` 协议映射进 GraphQL 响应；前端按 code
  精确查中文文案（web/lib/payment-errors.ts / miniprogram/src/domain/error-copy.ts），
  不做英文 message 正则匹配。

  模板：`Cgc2046.Accounts.PlatformAdminError`（Splode.Error + AshGraphql.Error 协议）。
  """
  use Splode.Error, fields: [:message, :code, :fields], class: :invalid

  def message(error), do: error.message
end

defimpl AshGraphql.Error, for: Cgc2046.Errors.BusinessError do
  def to_error(error) do
    %{
      message: error.message,
      short_message: error.message,
      code: error.code,
      vars: %{},
      fields: List.wrap(error.fields || [])
    }
  end
end
