defmodule Cgc2046.Accounts.PhoneCodeSignIn do
  @moduledoc """
  手机验证码登录流程（plan 002 U3）。

  验码（原子消费）→ find-or-create User by phone（`SignInFlow`，与小程序
  find-or-create 同款，用户不存在自动建号）→ 吊销旧 token → 签 JWT
  （无 platform claim——web 端登录与密码登录同形）。

  错误统一 `{:error, :invalid_or_expired_code}`（防枚举：不区分码不存在/
  过期/错码/耗尽）。
  """

  alias Cgc2046.Accounts.{PhoneVerificationCode, SignInFlow}

  @typedoc "签发结果：user 已挂 `__metadata__[:token]`"
  @type sign_in_result :: {:ok, Cgc2046.Accounts.User.t()} | {:error, term()}

  @doc """
  验证码登录入口。

  - 验码失败（含码不可用）→ `{:error, :invalid_or_expired_code}`
  - 建号/入座/吊销/签发失败 → 透传原始错误（调用方统一 500 语义）
  """
  @spec sign_in_with_phone_code(String.t(), String.t(), map()) :: sign_in_result()
  def sign_in_with_phone_code(phone, code, context)
      when is_binary(phone) and is_binary(code) do
    with :ok <- PhoneVerificationCode.consume_valid(phone, code, :login),
         {:ok, user, created?} <- SignInFlow.find_or_create_user(phone),
         :ok <- SignInFlow.maybe_admit_to_default_workspace(user, created?),
         :ok <- SignInFlow.revoke_stored_tokens(user),
         {:ok, user} <- SignInFlow.generate_token(user, nil, context) do
      {:ok, user}
    else
      {:error, :invalid_code} -> {:error, :invalid_or_expired_code}
      {:error, :code_not_available} -> {:error, :invalid_or_expired_code}
      {:error, reason} -> {:error, reason}
    end
  end
end
