defmodule Cgc2046Web.GraphqlSchema.Auth.Helpers do
  @moduledoc """
  认证域域内 resolver helper：手机验证码登录、平台登录限流识别与
  bearer token 撤销；仅本域 notation 模块使用。
  """

  require Logger

  @doc """
  账号密码登录的共享实现（web `signIn` 与第一方客户端 `signInForDesktop` 共用）：
  含 @ 走邮箱，否则手机号归一化后走手机号策略；失败统一映射为 `:authentication_failed`
  （防枚举，不新增错误出口）。
  """
  def sign_in_with_password_or_phone(login, password) do
    query =
      if String.contains?(login, "@") do
        Cgc2046.Accounts.User
        |> Ash.Query.for_read(:sign_in_with_password, %{email: login, password: password})
      else
        case Cgc2046.Accounts.PhoneNumber.normalize(login) do
          {:ok, phone} ->
            Cgc2046.Accounts.User
            |> Ash.Query.for_read(:sign_in_with_password_phone, %{
              phone: phone,
              password: password
            })

          {:error, :invalid} ->
            # 非法手机号格式：走 email 分支产出统一的认证失败（防枚举语义不变）
            Cgc2046.Accounts.User
            |> Ash.Query.for_read(:sign_in_with_password, %{email: login, password: password})
        end
      end

    try do
      case Ash.read(query) do
        {:ok, [user]} -> {:ok, user}
        {:error, _error} -> {:error, :authentication_failed}
      end
    rescue
      error ->
        # 不把登录标识写日志；只记录异常类型，保留可诊断性。
        Logger.error("[sign_in] password sign-in raised: #{inspect(error.__struct__)}")
        {:error, :authentication_failed}
    end
  end

  @doc """
  为第一方桌面客户端签发带 `platform=desktop` claim 的 JWT（与 web token 区分，
  避免 web 面重登吊销误杀桌面会话）。策略 read action 已签发过一枚 web 面 token，
  这里 best-effort 撤销它，只把 desktop token 返回给客户端。
  """
  def issue_desktop_token(user) do
    case Cgc2046.Accounts.SignInFlow.generate_token(user, :desktop, %{}) do
      {:ok, signed_user} ->
        case signed_user.__metadata__[:token] do
          token when is_binary(token) and byte_size(token) > 0 ->
            revoke_orphan_strategy_token(user.__metadata__[:token], token)
            {:ok, token}

          _ ->
            {:error, :token_generation_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revoke_orphan_strategy_token(nil, _desktop_token), do: :ok

  defp revoke_orphan_strategy_token(strategy_token, desktop_token)
       when strategy_token == desktop_token,
       do: :ok

  defp revoke_orphan_strategy_token(strategy_token, _desktop_token) do
    case AshAuthentication.TokenResource.Actions.revoke(
           Cgc2046.Accounts.Token,
           strategy_token,
           []
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        # 孤儿 token 仍在 7 天内有效，但不返回给客户端；记录以便观察。
        Logger.warning("desktop sign-in orphan token revoke failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  撤销当前请求携带的 Bearer token。调用方必须已通过 `load_actor`（actor 非 nil），
  这样才是「持有并验证过该 token 的调用者」，而不是只凭 header 里任意字符串写库。
  返回 `:ok | :unauthenticated | {:error, reason}`。
  """
  def revoke_current_bearer(context) do
    case {context[:actor], context[:cgc_bearer_token]} do
      {nil, _} ->
        :unauthenticated

      {_actor, token} when is_binary(token) and byte_size(token) > 0 ->
        case AshAuthentication.TokenResource.Actions.revoke(
               Cgc2046.Accounts.Token,
               token,
               []
             ) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("revokeToken failed: #{inspect(reason)}")
            {:error, reason}
        end

      _ ->
        :unauthenticated
    end
  end

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
    case revoke_current_bearer(context) do
      {:error, reason} -> Logger.warning("signOut token revoke failed: #{inspect(reason)}")
      _ -> :ok
    end
  end
end
