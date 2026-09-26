defmodule Cgc2046.Accounts.PlatformIdentitySignIn do
  @moduledoc """
  小程序回访静默登录（#930）：只用平台登录凭证（wx.login / tt.login / xhs.login 的 code），
  不走手机号授权——code2session → openid 限流（与手机号登录共用一个桶）→ 按
  (provider, openid) 查已绑定的 UserIdentity → 吊销该平台旧 token → 签发带 platform claim 的 JWT。

  首次登录仍必须走手机号（手机号是 User 锚，Q2）：没有绑定身份 → `:identity_not_found`，
  前端退回手机号登录。计费的手机号接口在这条路径上一次都不调用——这是本流程存在的理由。

  安全性来自 code 本身：code 由微信客户端一次性签发、服务端凭 app secret 换 openid，
  能拿到有效 code 的只有这个微信用户本人。只按本平台 openid 查找，不做 unionid 跨应用合并
  （同 `WechatWebSignIn` 的 ① 路径；② 路径的跨应用合并本流程不需要）。
  session_key 红线同 SignInPreparation：只在 Client 调用栈内流转。
  """

  require Ash.Query

  alias Cgc2046.Accounts.{SignInFlow, User, UserIdentity}
  alias Cgc2046.Integrations.Wechat.Client

  @internal_opts [context: %{private: %{ash_authentication?: true}}]
  @platforms %{"wechat" => :wechat, "tt" => :tt, "xhs" => :xhs}

  @spec sign_in(String.t(), String.t(), map()) :: {:ok, User.t()} | {:error, term()}
  def sign_in(platform, code, context) when is_binary(platform) and is_binary(code) do
    with {:ok, platform} <- parse_platform(platform),
         {:ok, session} <- Client.code2session(platform, code),
         :ok <- SignInFlow.check_openid_rate(platform, session.openid),
         {:ok, user} <- find_user(platform, session.openid),
         :ok <- SignInFlow.revoke_stored_tokens(user, platform),
         {:ok, user} <- SignInFlow.generate_token(user, platform, context) do
      {:ok, user}
    end
  end

  defp parse_platform(platform) do
    case Map.fetch(@platforms, platform) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :invalid_platform}
    end
  end

  defp find_user(platform, openid) do
    identity =
      UserIdentity
      |> Ash.Query.filter(provider == ^platform and uid == ^openid)
      |> Ash.read_one(@internal_opts)

    with {:ok, %UserIdentity{user_id: user_id}} <- identity,
         {:ok, %User{} = user} <-
           User |> Ash.Query.filter(id == ^user_id) |> Ash.read_one(@internal_opts) do
      {:ok, user}
    else
      {:ok, nil} -> {:error, :identity_not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end
