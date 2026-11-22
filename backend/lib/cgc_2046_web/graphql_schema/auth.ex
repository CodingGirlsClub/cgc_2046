defmodule Cgc2046Web.GraphqlSchema.Auth do
  @moduledoc """
  认证与会话域 GraphQL 面上半：登录 / 注册 / 验证码 / 微信绑定的 mutation 字段
  （密码重置 / 设密 / 平台身份登录 / 登出与撤销在 `Auth.AccountSessionMutations`；
  本域无 query 段——me / my_phone 归用户自助面）；类型在 `Auth.Types`，域内 helper 在 `Auth.Helpers`。
  """

  use Absinthe.Schema.Notation

  import_types(Cgc2046Web.GraphqlSchema.Auth.Types)

  import Cgc2046Web.GraphqlSchema.Auth.Helpers

  require Logger

  object :auth_mutations do
    @desc "账号密码登录（plan 002 U2：login 含 @ 走邮箱，否则手机号归一化；token 经 httpOnly cookie 交付）"
    field :sign_in, :sign_in_result do
      arg(:login, non_null(:string))
      arg(:password, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit,
        ip_bucket: "sign-in",
        ip_context_key: :mini_web_ip,
        limit: :sign_in_ip,
        window_seconds: 900
      )

      middleware(Cgc2046Web.Plugs.RateLimit,
        key_path: [:login],
        ip_context_key: :mini_web_ip,
        normalize: &Cgc2046.Accounts.WebAuthFlow.normalize_login/1
      )

      resolve(fn _, %{login: login, password: password}, _ ->
        case sign_in_with_password_or_phone(login, password) do
          {:ok, user} ->
            {:ok,
             %{
               id: user.id,
               email: user.email,
               is_platform_admin: user.is_platform_admin,
               # token 仅用于 middleware 传递到 before_send 写 httpOnly cookie，不暴露在响应中
               __token__: user.__metadata__[:token]
             }}

          {:error, :authentication_failed} ->
            {:error, message: "Invalid email or password", code: "authentication_failed"}
        end
      end)

      middleware(fn res, _ ->
        case res.value do
          %{__token__: token} when is_binary(token) ->
            %{res | context: Map.put(res.context, :cgc_auth_token, token)}

          _ ->
            res
        end
      end)
    end

    @desc """
    第一方客户端登录：直接返回 Bearer JWT（响应体交付，不写 httpOnly cookie）。
    与 web 的 `signIn` 共用同一 AshAuthentication token；撤销用 `revokeToken`。
    """
    field :sign_in_for_desktop, :desktop_sign_in_result do
      arg(:login, non_null(:string))
      arg(:password, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit,
        ip_bucket: "sign-in",
        ip_context_key: :mini_web_ip,
        limit: :sign_in_ip,
        window_seconds: 900
      )

      middleware(Cgc2046Web.Plugs.RateLimit,
        key_path: [:login],
        ip_context_key: :mini_web_ip,
        normalize: &Cgc2046.Accounts.WebAuthFlow.normalize_login/1
      )

      resolve(fn _, %{login: login, password: password}, _ ->
        case sign_in_with_password_or_phone(login, password) do
          {:ok, user} ->
            case issue_desktop_token(user) do
              {:ok, token} ->
                {:ok,
                 %{
                   token: token,
                   user_id: user.id,
                   email: user.email,
                   is_platform_admin: user.is_platform_admin
                 }}

              {:error, reason} ->
                Logger.error("signInForDesktop token generation failed: #{inspect(reason)}")
                {:error, message: "Sign in failed", code: "authentication_failed"}
            end

          {:error, :authentication_failed} ->
            {:error, message: "Invalid email or password", code: "authentication_failed"}
        end
      end)
    end

    @desc "桌面端手机验证码登录/注册：JWT 直接经响应体交付（第一方客户端，不写 cookie）"
    field :sign_in_with_phone_code_for_desktop, :desktop_sign_in_result do
      arg(:phone, non_null(:string))
      arg(:code, non_null(:string))

      resolve(fn _, %{phone: raw_phone, code: code}, %{context: context} ->
        with {:ok, phone} <- Cgc2046.Accounts.PhoneNumber.normalize(raw_phone),
             :ok <- Cgc2046.Accounts.WebAuthFlow.check_phone_code_verify_limits(context, phone) do
          case Cgc2046.Accounts.PhoneCodeSignIn.sign_in_with_phone_code(phone, code, context) do
            {:ok, user} ->
              case issue_desktop_token(user) do
                {:ok, token} ->
                  {:ok,
                   %{
                     token: token,
                     user_id: user.id,
                     email: user.email,
                     is_platform_admin: user.is_platform_admin
                   }}

                {:error, reason} ->
                  Logger.error(
                    "signInWithPhoneCodeForDesktop token generation failed: #{inspect(reason)}"
                  )

                  {:error, message: "Sign in failed", code: "authentication_failed"}
              end

            {:error, :invalid_or_expired_code} ->
              {:error, message: "Invalid or expired code", code: "invalid_or_expired_code"}

            {:error, reason} ->
              Logger.warning("[signInWithPhoneCodeForDesktop] failed: #{inspect(reason)}")
              {:error, message: "Sign in failed", code: "phone_code_sign_in_failed"}
          end
        else
          {:error, :invalid} ->
            {:error, message: "Invalid phone number", code: "invalid_phone"}

          {:error, :rate_limited} ->
            {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
        end
      end)
    end

    @desc "请求发送手机验证码（plan 002 U3；限流 phone 1/60s + 5/1h + 20/1d、IP 30/1d）"
    field :request_phone_code, :request_phone_code_result do
      arg(:phone, non_null(:string))
      arg(:purpose, non_null(:phone_code_purpose))

      resolve(fn _, %{phone: raw_phone, purpose: purpose}, %{context: context} ->
        with {:ok, phone} <- Cgc2046.Accounts.PhoneNumber.normalize(raw_phone),
             :ok <- Cgc2046.Accounts.WebAuthFlow.check_phone_code_request_limits(context, phone) do
          Cgc2046.Accounts.WebAuthFlow.request_phone_code(phone, purpose)
        else
          {:error, :invalid} ->
            {:error, message: "Invalid phone number", code: "invalid_phone"}

          {:error, :rate_limited} ->
            {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
        end
      end)
    end

    @desc "手机验证码登录（plan 002 U3；用户不存在自动建号；token 经 httpOnly cookie 交付）"
    field :sign_in_with_phone_code, :sign_in_with_phone_code_result do
      arg(:phone, non_null(:string))
      arg(:code, non_null(:string))

      resolve(fn _, %{phone: raw_phone, code: code}, %{context: context} ->
        with {:ok, phone} <- Cgc2046.Accounts.PhoneNumber.normalize(raw_phone),
             :ok <- Cgc2046.Accounts.WebAuthFlow.check_phone_code_verify_limits(context, phone) do
          sign_in_with_phone_code(phone, code, context)
        else
          {:error, :invalid} ->
            {:error, message: "Invalid phone number", code: "invalid_phone"}

          {:error, :rate_limited} ->
            {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
        end
      end)

      middleware(fn res, _ ->
        case res.value do
          %{__token__: token} when is_binary(token) ->
            %{res | context: Map.put(res.context, :cgc_auth_token, token)}

          _ ->
            res
        end
      end)
    end

    @desc "发起微信扫码登录（plan 002 U4；未配置 → wechat_login_unavailable；IP 20/15min 限流）"
    field :wechat_login_start, :wechat_login_start_result do
      @desc "发起微信扫码登录(plan 002 U4);next 透传进 redirect_uri(callback 页同源校验后跳转)"
      arg(:next, :string)

      resolve(fn _, args, %{context: context} ->
        if Cgc2046.Integrations.Wechat.WebOAuth.configured?() do
          with :ok <- Cgc2046.Accounts.WebAuthFlow.check_wechat_login_start_limits(context) do
            Cgc2046.Accounts.WebAuthFlow.start_wechat_login(args[:next])
          else
            {:error, :rate_limited} ->
              {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
          end
        else
          {:error, message: "WeChat login is unavailable", code: "wechat_login_unavailable"}
        end
      end)

      # advisor02 M2：state 经 before_send 下发 httpOnly cgc_wechat_state cookie
      # 绑定发起浏览器（WechatStatePlug 读回校验）
      middleware(fn res, _ ->
        case res.value do
          %{state: state} when is_binary(state) ->
            %{res | context: Map.put(res.context, :cgc_wechat_state_set, state)}

          _ ->
            res
        end
      end)
    end

    @desc "微信扫码回调（plan 002 U4；IP 20/15min 限流）：已绑定直登，未绑定返回绑定票据"
    field :sign_in_with_wechat, :sign_in_with_wechat_result do
      arg(:code, non_null(:string))
      arg(:state, non_null(:string))

      resolve(fn _, %{code: code, state: state}, %{context: context} ->
        with :ok <- Cgc2046.Accounts.WebAuthFlow.check_wechat_callback_limits(context) do
          case Cgc2046.Accounts.WechatWebSignIn.sign_in_with_wechat(state, code, context) do
            {:ok, :signed_in, user} ->
              {:ok,
               %{
                 status: :signed_in,
                 bind_ticket: nil,
                 __token__: user.__metadata__[:token]
               }}

            {:ok, :needs_binding, bind_ticket} ->
              {:ok, %{status: :needs_binding, bind_ticket: bind_ticket}}

            {:error, reason} ->
              # 防枚举：客户端只收统一错误；服务端只记白名单分类，原始
              # code/token/身份值与下游 error struct 均不得进入日志。
              summary = Cgc2046.Accounts.WebAuthFlow.summarize_wechat_sign_in_failure(reason)
              Logger.warning("[wechat_web sign_in] failed: #{inspect(summary)}")

              {:error, message: "WeChat sign in failed", code: "wechat_sign_in_failed"}
          end
        else
          {:error, :rate_limited} ->
            {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
        end
      end)

      middleware(fn res, _ ->
        case res.value do
          %{__token__: token} when is_binary(token) ->
            %{res | context: Map.put(res.context, :cgc_auth_token, token)}

          _ ->
            res
        end
      end)
    end

    @desc "微信扫码绑定手机号完成登录（plan 002 U4；phone 5/15min 限流）"
    field :bind_wechat_with_phone, :sign_in_with_phone_code_result do
      arg(:bind_ticket, non_null(:string))
      arg(:phone, non_null(:string))
      arg(:code, non_null(:string))

      resolve(fn _,
                 %{bind_ticket: bind_ticket, phone: raw_phone, code: code},
                 %{context: context} ->
        with {:ok, phone} <- Cgc2046.Accounts.PhoneNumber.normalize(raw_phone),
             :ok <- Cgc2046.Accounts.WebAuthFlow.check_wechat_bind_limits(context, phone) do
          case Cgc2046.Accounts.WechatWebSignIn.bind_wechat_with_phone(
                 bind_ticket,
                 phone,
                 code,
                 context
               ) do
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

            {:error, :invalid_bind_ticket} ->
              {:error, message: "Invalid binding session", code: "invalid_bind_ticket"}

            {:error, _reason} ->
              {:error, message: "Binding failed", code: "wechat_bind_failed"}
          end
        else
          {:error, :invalid} ->
            {:error, message: "Invalid phone number", code: "invalid_phone"}

          {:error, :rate_limited} ->
            {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
        end
      end)

      middleware(fn res, _ ->
        case res.value do
          %{__token__: token} when is_binary(token) ->
            %{res | context: Map.put(res.context, :cgc_auth_token, token)}

          _ ->
            res
        end
      end)
    end

    @desc "手机号注册（验证码 + 密码；httpOnly cookie 交付 token，自动登录）"
    field :sign_up_with_phone, :sign_up_with_phone_payload do
      arg(:input, non_null(:sign_up_with_phone_input))

      resolve(fn _, %{input: %{phone: raw_phone, code: code, password: password}}, ctx ->
        context = ctx.context

        with {:ok, phone} <- Cgc2046.Accounts.PhoneNumber.normalize(raw_phone),
             :ok <- Cgc2046.Accounts.WebAuthFlow.check_phone_code_verify_limits(context, phone) do
          Cgc2046.Accounts.WebAuthFlow.sign_up_with_phone(phone, code, password, context)
        else
          {:error, :invalid} ->
            {:error, message: "Invalid phone number", code: "invalid_phone"}

          {:error, :rate_limited} ->
            {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
        end
      end)

      middleware(fn res, _ ->
        case res.value do
          %{__token__: token} when is_binary(token) ->
            %{res | context: Map.put(res.context, :cgc_auth_token, token)}

          _ ->
            res
        end
      end)
    end
  end
end
