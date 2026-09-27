defmodule Cgc2046Web.GraphqlSchema.Auth.Helpers do
  @moduledoc """
  认证域域内 resolver helper：手机验证码登录、平台登录限流识别与
  bearer token 撤销；仅本域 notation 模块使用。
  """

  require Logger

  def sign_in_with_phone_code(phone, code, context) do
    case Cgc2046.Accounts.PhoneCodeSignIn.sign_in_with_phone_code(phone, code, context) do
      {:ok, user} ->
        {:ok,
         %{
           id: user.id,
           email: user.email,
           is_platform_admin: user.is_platform_admin,
           __token__: user.__metadata__[:token]
         }}

      {:error, :invalid_or_expired_code} ->
        {:error, message: "Invalid or expired code", code: "invalid_or_expired_code"}

      {:error, reason} ->
        Logger.warning("[signInWithPhoneCode] failed: #{inspect(reason)}")
        {:error, message: "Sign in failed", code: "phone_code_sign_in_failed"}
    end
  end

  # #930：SignInPreparation 把 openid 限流标成 caused_by.reason = :rate_limited；其余失败
  # 一律统一为 authentication_failed（防枚举）。限流如实告知：openid 来自请求者自己的 code，不泄露他人信息。
  def platform_sign_in_rate_limited?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &platform_sign_in_rate_limited?/1)

  def platform_sign_in_rate_limited?(%AshAuthentication.Errors.AuthenticationFailed{
        caused_by: %{reason: :rate_limited}
      }),
      do: true

  def platform_sign_in_rate_limited?(_), do: false

  # 服务端撤销当前 token：往 tokens 表对当前 jti 做 upsert，把 purpose 从 "user"
  # 覆盖成 "revocation"，下次 load_from_bearer 的 get_token 查不到 user 记录即认证失败。
  # token 由 AuthTokenContextPlug 从 Authorization header 透传进 Absinthe context。
  # 撤销失败不阻断登出：仍清 cookie 让用户侧登出成功，token 会在 7 天自然过期。
  def revoke_bearer_token(context) do
    case context[:cgc_bearer_token] do
      token when is_binary(token) and byte_size(token) > 0 ->
        case AshAuthentication.TokenResource.Actions.revoke(Cgc2046.Accounts.Token, token, []) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("signOut token revoke failed: #{inspect(reason)}")
        end

      _ ->
        :ok
    end
  end
end
