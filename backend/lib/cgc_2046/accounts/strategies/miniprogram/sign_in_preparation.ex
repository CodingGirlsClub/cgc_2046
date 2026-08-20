defmodule Cgc2046.Accounts.Strategies.Miniprogram.SignInPreparation do
  @moduledoc """
  `:miniprogram` 策略登录流程（read action 的 after_action 内完成全部工作，
  与 password 策略 SignInPreparation 同构——错误以裸 `AuthenticationFailed` 返回，
  保持 ash_graphql / ash_authentication_phoenix 的 401 映射语义）。

  步骤：
  1. code2session → openid/unionid/session_key（`Cgc2046.Miniprogram.Client`）
  2. session_key 解密手机号（无手机号不建号——Q2：平台验证手机号为 User 锚）
  3. find-or-create User by phone（`Cgc2046.Accounts.SignInFlow`，plan 002 U3 抽取）
  4. upsert UserIdentity（provider/uid/unionid；换绑手机号时随新锚重指向）
  5. 吊销该 subject 全部已存 token（重登吊销旧 jti，白名单既有能力）
  6. 签发带 platform claim 的 JWT（存 metadata `:token`）

  红线：session_key 只在 `Client` 调用栈内流转，不落 query context / 日志 / DB / 响应。
  """
  use Ash.Resource.Preparation

  alias Ash.Query
  alias AshAuthentication.Errors.AuthenticationFailed
  alias Cgc2046.Accounts.{SignInFlow, UserIdentity}
  alias Cgc2046.Miniprogram.Client

  require Logger

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
    phone_code = Query.get_argument(query, :phone_code)
    encrypted_data = Query.get_argument(query, :encrypted_data)
    iv = Query.get_argument(query, :iv)

    with {:ok, session} <- Client.code2session(platform, code),
         {:ok, phone} <- fetch_phone(platform, session, phone_code, encrypted_data, iv),
         {:ok, user, created?} <- SignInFlow.find_or_create_user(phone),
         :ok <- SignInFlow.maybe_admit_to_default_workspace(user, created?),
         :ok <- attach_identity(platform, session, user),
         :ok <- SignInFlow.revoke_stored_tokens(user, platform),
         {:ok, user} <- SignInFlow.generate_token(user, platform, context) do
      {:ok, user}
    end
  end

  # 手机号获取优先级：wechat + phone_code → 新 API（不触碰 session_key）；
  # 否则 legacy session_key 解密。组合不完整（phone_code 缺且 encrypted_data/iv
  # 不齐；或非 wechat 平台只给 phone_code）→ 统一认证失败（防枚举语义不变）。
  defp fetch_phone(:wechat, %{openid: openid}, phone_code, _encrypted_data, _iv)
       when is_binary(phone_code) and phone_code != "" do
    Client.fetch_phone_by_code(:wechat, openid, phone_code)
  end

  defp fetch_phone(platform, session, nil, encrypted_data, iv)
       when platform in [:wechat, :tt, :xhs] do
    Client.decrypt_phone(platform, session, encrypted_data, iv)
  end

  defp fetch_phone(_platform, _session, _phone_code, _encrypted_data, _iv),
    do: {:error, :phone_payload_incomplete}

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
