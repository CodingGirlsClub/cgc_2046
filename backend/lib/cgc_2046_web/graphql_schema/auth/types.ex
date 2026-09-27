defmodule Cgc2046Web.GraphqlSchema.Auth.Types do
  @moduledoc """
  认证域 GraphQL 类型（#60 路径 B：httpOnly cookie 交付 token）；仅本域
  notation 模块 import_types 使用。
  """

  use Absinthe.Schema.Notation

  # ── 认证相关类型（#60 路径 B：httpOnly cookie 交付 token） ──────────────
  # （schema 级 middleware/3 callback——validate_invitation 的 RateLimit 挂载——
  # 是 Absinthe.Schema 的 callback，留在 schema 本体，不在本 notation 模块）

  object :sign_in_result do
    field(:id, non_null(:id))
    field(:email, non_null(:string))
    field(:is_platform_admin, non_null(:boolean))
  end

  object :request_password_reset_result do
    field(:sent, non_null(:boolean))
  end

  object :reset_password_result do
    field(:ok, non_null(:boolean))
  end

  # 小程序手机号用户无邮箱 → email 可空（与 users.email 放宽一致）
  object :sign_in_with_platform_result do
    field(:id, non_null(:id))
    field(:email, :string)
    field(:is_platform_admin, non_null(:boolean))
  end

  # 手机验证码登录（plan 002 U3）：phone 用户 email 可空（同 platform result）
  object :request_phone_code_result do
    field(:sent, non_null(:boolean))
    field(:retry_after_seconds, non_null(:integer))
  end

  enum :phone_code_purpose do
    value(:login)
    value(:wechat_bind)
    value(:register)
    value(:change_phone)
  end

  object :sign_in_with_phone_code_result do
    field(:id, non_null(:id))
    field(:email, :string)
    field(:is_platform_admin, non_null(:boolean))
  end

  # 微信扫码登录（plan 002 U4）
  object :wechat_login_start_result do
    field(:qr_url, non_null(:string))
    field(:state, non_null(:string))
    field(:expires_in_seconds, non_null(:integer))
  end

  object :sign_in_with_wechat_result do
    field(:status, non_null(:wechat_sign_in_status))
    field(:bind_ticket, :string)
  end

  enum :wechat_sign_in_status do
    value(:signed_in)
    value(:needs_binding)
  end

  @desc "手机号注册结果（email 可空——无邮箱手机号用户，同 phone code 登录 result）"
  object :sign_up_with_phone_user do
    field(:id, non_null(:id))
    field(:email, :string)
    field(:is_platform_admin, non_null(:boolean))
  end

  object :sign_up_with_phone_payload do
    field(:result, :sign_up_with_phone_user)
    field(:errors, list_of(:mutation_error))
  end

  input_object :sign_up_with_phone_input do
    field(:phone, non_null(:string))
    field(:code, non_null(:string))
    field(:password, non_null(:string))
  end
end
