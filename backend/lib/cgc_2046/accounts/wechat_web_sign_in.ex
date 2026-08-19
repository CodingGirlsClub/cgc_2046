defmodule Cgc2046.Accounts.WechatWebSignIn do
  @moduledoc """
  微信扫码登录流程（plan 002 U4）。

  `sign_in_with_wechat/3`：验 state（pending + 未过期）→ code2access_token →
  UserIdentity 查找顺序 ①(provider :wechat_web, uid openid) ②unionid 匹配
  任意 wechat 系 identity（跨应用合并）→ 命中：消费 ticket + 吊销 + 签 JWT →
  `{:ok, :signed_in, user}`；未命中：ticket 迁移 needs_binding →
  `{:ok, :needs_binding, bind_ticket}`。

  `bind_wechat_with_phone/4`：验 ticket(needs_binding) → 验 phone code
  (purpose :wechat_bind) → find-or-create User（SignInFlow）→ upsert
  UserIdentity(:wechat_web) → 消费 ticket → 签 JWT。

  错误统一防枚举语义（:wechat_sign_in_failed / :invalid_or_expired_code）。
  """

  require Ash.Query
  require Logger

  alias Ash.Changeset
  alias Cgc2046.Accounts.{PhoneVerificationCode, SignInFlow, UserIdentity, WechatLoginTicket}
  alias Cgc2046.OAuth.WechatWeb

  @internal_opts [context: %{private: %{ash_authentication?: true}}]

  # ── signInWithWechat ───────────────────────────────────────────────────

  @spec sign_in_with_wechat(String.t(), String.t(), map()) ::
          {:ok, :signed_in, Cgc2046.Accounts.User.t()}
          | {:ok, :needs_binding, String.t()}
          | {:error, term()}
  def sign_in_with_wechat(state, code, context)
      when is_binary(state) and is_binary(code) do
    with {:ok, _ticket} <- WechatLoginTicket.fetch_pending(state),
         {:ok, session} <- WechatWeb.code2access_token(code) do
      case find_user_by_wechat(session) do
        {:ok, %Cgc2046.Accounts.User{} = user} ->
          with :ok <- WechatLoginTicket.consume_now(state),
               :ok <- SignInFlow.revoke_stored_tokens(user),
               {:ok, user} <- SignInFlow.generate_token(user, nil, context) do
            {:ok, :signed_in, user}
          else
            {:error, reason} -> {:error, reason}
          end

        {:ok, nil} ->
          case WechatLoginTicket.mark_needs_binding(state, session) do
            {:ok, _} -> {:ok, :needs_binding, state}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ① provider :wechat_web + uid openid；② unionid 匹配任意 wechat 系
  # identity（wechat/wechat_web——开放平台同主体 UnionID 一致，跨应用合并）
  defp find_user_by_wechat(%{openid: openid, unionid: unionid}) do
    identity =
      UserIdentity
      |> Ash.Query.filter(provider == :wechat_web and uid == ^openid)
      |> Ash.read_one(@internal_opts)

    case identity do
      {:ok, %UserIdentity{user_id: user_id}} ->
        fetch_user(user_id)

      {:ok, nil} when is_binary(unionid) ->
        identity_by_unionid =
          UserIdentity
          |> Ash.Query.filter(unionid == ^unionid and provider in [:wechat, :wechat_web])
          |> Ash.read_one(@internal_opts)

        case identity_by_unionid do
          {:ok, %UserIdentity{user_id: user_id}} -> fetch_user(user_id)
          {:ok, nil} -> {:ok, nil}
          {:error, reason} -> {:error, reason}
        end

      {:ok, nil} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_user(user_id) do
    Cgc2046.Accounts.User
    |> Ash.Query.filter(id == ^user_id)
    |> Ash.read_one(@internal_opts)
  end

  # ── bindWechatWithPhone ────────────────────────────────────────────────

  @spec bind_wechat_with_phone(String.t(), String.t(), String.t(), map()) ::
          {:ok, Cgc2046.Accounts.User.t()} | {:error, term()}
  def bind_wechat_with_phone(bind_ticket, phone, code, context)
      when is_binary(bind_ticket) and is_binary(phone) and is_binary(code) do
    with {:ok, ticket} <- WechatLoginTicket.consume_for_binding(bind_ticket),
         :ok <- PhoneVerificationCode.consume_valid(phone, code, :wechat_bind),
         {:ok, user, created?} <- SignInFlow.find_or_create_user(phone),
         :ok <- SignInFlow.maybe_admit_to_default_workspace(user, created?),
         :ok <- upsert_identity(ticket, user),
         :ok <- SignInFlow.revoke_stored_tokens(user),
         {:ok, user} <- SignInFlow.generate_token(user, nil, context) do
      {:ok, user}
    else
      {:error, :ticket_invalid} -> {:error, :invalid_bind_ticket}
      {:error, :invalid_code} -> {:error, :invalid_or_expired_code}
      {:error, :code_not_available} -> {:error, :invalid_or_expired_code}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_identity(ticket, user) do
    UserIdentity
    |> Changeset.for_create(:upsert, %{
      provider: :wechat_web,
      uid: ticket.openid,
      unionid: ticket.unionid,
      user_id: user.id
    })
    |> Ash.create(@internal_opts)
    |> case do
      {:ok, _identity} ->
        :ok

      {:error, error} ->
        Logger.warning("[wechat_web sign_in] identity upsert failed: #{inspect(error)}")
        {:error, :identity_attach_failed}
    end
  end
end
