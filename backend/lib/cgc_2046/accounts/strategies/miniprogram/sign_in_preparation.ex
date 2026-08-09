defmodule Cgc2046.Accounts.Strategies.Miniprogram.SignInPreparation do
  @moduledoc """
  `:miniprogram` 策略登录流程（read action 的 after_action 内完成全部工作，
  与 password 策略 SignInPreparation 同构——错误以裸 `AuthenticationFailed` 返回，
  保持 ash_graphql / ash_authentication_phoenix 的 401 映射语义）。

  步骤：
  1. code2session → openid/unionid/session_key（`Cgc2046.Miniprogram.Client`）
  2. session_key 解密手机号（无手机号不建号——Q2：平台验证手机号为 User 锚）
  3. find-or-create User by phone（部分唯一索引兜底并发，败者重读）
  4. upsert UserIdentity（provider/uid/unionid；换绑手机号时随新锚重指向）
  5. 吊销该 subject 全部已存 token（重登吊销旧 jti，白名单既有能力）
  6. 签发带 platform claim 的 JWT（存 metadata `:token`）

  红线：session_key 只在 `Client` 调用栈内流转，不落 query context / 日志 / DB / 响应。
  """
  use Ash.Resource.Preparation

  alias Ash.Query
  alias AshAuthentication.{Errors.AuthenticationFailed, Jwt}
  alias Cgc2046.Accounts.{MembershipContext, Token, User, UserIdentity}
  alias Cgc2046.Miniprogram.Client

  require Logger

  # 内部数据操作统一走 ash_authentication 私有 context（命中 User/Token/UserIdentity
  # 的 AshAuthenticationInteraction bypass），与 ash_authentication 自身实现一致。
  @internal_opts [context: %{private: %{ash_authentication?: true}}]

  @impl true
  def prepare(query, _opts, context) do
    query
    # 结果集由 after_action 合成（登录目标 User 由平台手机号解析，非查询过滤得出），
    # 基查询置空避免全表扫描。
    |> Query.filter(false)
    |> Query.after_action(fn query, _results ->
      case do_sign_in(query, context) do
        {:ok, user} -> {:ok, [user]}
        {:error, reason} -> {:error, authentication_failed(query, reason)}
      end
    end)
  end

  defp do_sign_in(query, context) do
    platform = Query.get_argument(query, :platform)
    code = Query.get_argument(query, :code)
    encrypted_data = Query.get_argument(query, :encrypted_data)
    iv = Query.get_argument(query, :iv)

    with {:ok, session} <- Client.code2session(platform, code),
         {:ok, phone} <- Client.decrypt_phone(platform, session, encrypted_data, iv),
         {:ok, user, created?} <- find_or_create_user(phone),
         :ok <- maybe_admit_to_default_workspace(user, created?),
         :ok <- attach_identity(platform, session, user),
         :ok <- revoke_stored_tokens(user),
         {:ok, user} <- generate_token(user, platform, context) do
      {:ok, user}
    end
  end

  # ── find-or-create（phone 锚定，抗并发）────────────────────────────────

  defp find_or_create_user(phone) do
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
         |> Ash.Changeset.for_create(:register_with_miniprogram, %{phone: phone})
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

  # ── UserIdentity 挂载（upsert，ON CONFLICT (provider, uid)）─────────────

  defp attach_identity(platform, session, user) do
    UserIdentity
    |> Ash.Changeset.for_create(:upsert, %{
      provider: platform,
      uid: session.openid,
      unionid: session.unionid,
      user_id: user.id
    })
    |> Ash.create(@internal_opts)
    |> case do
      {:ok, _identity} ->
        :ok

      {:error, error} ->
        Logger.warning("[miniprogram sign_in] identity upsert failed: #{inspect(error)}")
        {:error, :identity_attach_failed}
    end
  end

  # ── 重登吊销旧 jti（白名单既有能力）─────────────────────────────────────
  #
  # v1 可达状态内 subject 的 token 必为同平台（小程序用户无邮箱无 web 会话，
  # web 用户无手机号无小程序会话），故按 subject 全量吊销 == 按平台吊销。
  # 若未来打通 web/小程序绑定，需改为按 platform 维度吊销。

  defp revoke_stored_tokens(user) do
    subject = AshAuthentication.user_to_subject(user)

    with {:ok, tokens} <-
           Token
           |> Ash.Query.for_read(:stored_for_subject, %{subject: subject})
           |> Ash.read(@internal_opts),
         :ok <- revoke_each(tokens, subject) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("[miniprogram sign_in] token revocation failed: #{inspect(reason)}")
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

  # ── JWT 签发（platform claim）──────────────────────────────────────────

  defp generate_token(user, platform, context) do
    if AshAuthentication.Info.authentication_tokens_enabled?(user.__struct__) do
      case Jwt.token_for_user(
             user,
             %{"purpose" => "user", "platform" => to_string(platform)},
             Ash.Context.to_opts(context)
           ) do
        {:ok, token, _claims} -> {:ok, Ash.Resource.put_metadata(user, :token, token)}
        :error -> {:error, :token_generation_failed}
      end
    else
      {:ok, user}
    end
  end

  # ── 新用户默认工作台入座（对齐 signUp resolver 的降级语义）───────────────

  defp maybe_admit_to_default_workspace(_user, false), do: :ok

  defp maybe_admit_to_default_workspace(user, true) do
    case MembershipContext.admit_to_default_workspace(user.id) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[miniprogram sign_in] default workspace enroll failed: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[miniprogram sign_in] default workspace enroll raised: #{Exception.message(error)}"
      )

      :ok
  end

  # ── 统一认证失败（防枚举；reason 为净化后的原子/错误码，不含敏感值）─────

  defp authentication_failed(query, reason) do
    Logger.warning("[miniprogram sign_in] failed: #{inspect(reason)}")

    AuthenticationFailed.exception(
      strategy: :miniprogram,
      query: query,
      caused_by: %{
        module: __MODULE__,
        action: :sign_in,
        message: "Platform sign in failed"
      }
    )
  end
end
