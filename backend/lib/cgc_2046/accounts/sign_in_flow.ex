defmodule Cgc2046.Accounts.SignInFlow do
  @moduledoc """
  登录共享流程（plan 002 U3）：小程序登录（SignInPreparation）、手机验证码
  登录（PhoneCodeSignIn）、微信扫码绑定（WechatWebSignIn）共用的原子步骤。

  自 SignInPreparation 抽取（clean cutover，不留第二份）：

  - `find_or_create_user/1`：phone 锚定 find-or-create（race-retry，
    users_unique_phone_index 兜底并发）
  - `revoke_stored_tokens/1`：重登吊销 subject 全量已存 token（白名单能力）
  - `generate_token/3`：签 JWT（platform 可空——web 端登录无 platform claim）
  - `maybe_admit_to_default_workspace/2`：新用户默认工作台入座（降级语义）

  内部数据操作统一走 ash_authentication 私有 context（与原实现一致）。
  """

  require Logger
  require Ash.Query

  alias Ash.Changeset
  alias Ash.Query
  alias AshAuthentication.Jwt
  alias Cgc2046.Accounts.{MembershipContext, Token, User}

  @internal_opts [context: %{private: %{ash_authentication?: true}}]

  # ── find-or-create（phone 锚定，抗并发）────────────────────────────────

  @doc """
  按手机号 find-or-create User。返回 `{:ok, user, created?}`。
  """
  @spec find_or_create_user(String.t()) :: {:ok, User.t(), boolean()} | {:error, term()}
  def find_or_create_user(phone) when is_binary(phone) do
    case fetch_by_phone(phone) do
      {:ok, %User{} = user} -> {:ok, user, false}
      {:ok, nil} -> create_user_with_race_retry(phone)
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_by_phone(phone) do
    User
    |> Query.filter(phone: phone)
    |> Ash.read_one(@internal_opts)
  end

  defp create_user_with_race_retry(phone) do
    case User
         |> Changeset.for_create(:register_with_miniprogram, %{phone: phone})
         |> Ash.create(@internal_opts) do
      {:ok, user} ->
        {:ok, user, true}

      {:error, error} ->
        # 并发竞态：users_unique_phone_index（WHERE phone IS NOT NULL）保证只有一个
        # 创建者；败者在此重读拿到胜者已提交的行。非唯一冲突的失败重读不到 → 返回原错误。
        case fetch_by_phone(phone) do
          {:ok, %User{} = user} -> {:ok, user, false}
          _ -> {:error, error}
        end
    end
  end

  # ── 重登吊销旧 jti（白名单既有能力）─────────────────────────────────────

  @doc """
  吊销该 subject 全部已存 token。返回 `:ok | {:error, term}`。
  """
  @spec revoke_stored_tokens(User.t()) :: :ok | {:error, term()}
  def revoke_stored_tokens(user) do
    subject = AshAuthentication.user_to_subject(user)

    with {:ok, tokens} <-
           Token
           |> Query.for_read(:stored_for_subject, %{subject: subject})
           |> Ash.read(@internal_opts),
         :ok <- revoke_each(tokens, subject) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("[sign_in_flow] token revocation failed: #{inspect(reason)}")
        {:error, :token_revocation_failed}
    end
  end

  defp revoke_each(tokens, subject) do
    Enum.reduce_while(tokens, :ok, fn token, :ok ->
      case AshAuthentication.TokenResource.Actions.revoke_jti(
             Token,
             token.jti,
             subject,
             @internal_opts
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # ── JWT 签发 ───────────────────────────────────────────────────────────

  @doc """
  为 user 签 JWT（存 metadata `:token`）。`platform` 为 nil 时不带 platform
  claim（web 端登录与密码登录同形）。返回 `{:ok, user}`（metadata 已挂）。
  """
  @spec generate_token(User.t(), atom() | nil, Ash.Context.t() | map()) ::
          {:ok, User.t()} | {:error, term()}
  def generate_token(user, platform, context) do
    if AshAuthentication.Info.authentication_tokens_enabled?(user.__struct__) do
      extra_claims =
        %{"purpose" => "user"}
        |> maybe_put_platform(platform)

      case Jwt.token_for_user(user, extra_claims, Ash.Context.to_opts(context)) do
        {:ok, token, _claims} -> {:ok, Ash.Resource.put_metadata(user, :token, token)}
        :error -> {:error, :token_generation_failed}
      end
    else
      {:ok, user}
    end
  end

  defp maybe_put_platform(claims, nil), do: claims
  defp maybe_put_platform(claims, platform), do: Map.put(claims, "platform", to_string(platform))

  # ── 新用户默认工作台入座（对齐 signUp resolver 的降级语义）───────────────

  @doc """
  新用户（created? true）自动入座默认工作台；失败降级不阻断登录。
  """
  @spec maybe_admit_to_default_workspace(User.t(), boolean()) :: :ok
  def maybe_admit_to_default_workspace(_user, false), do: :ok

  def maybe_admit_to_default_workspace(user, true) do
    case MembershipContext.admit_to_default_workspace(user.id) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[sign_in_flow] default workspace enroll failed: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[sign_in_flow] default workspace enroll raised: #{Exception.message(error)}"
      )

      :ok
  end
end
