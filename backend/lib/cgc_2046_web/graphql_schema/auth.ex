defmodule Cgc2046Web.GraphqlSchema.Auth do
  @moduledoc """
  认证与会话域 GraphQL 面：登录 / 注册 / 验证码 / 密码重置 / 平台身份 /
  微信绑定 / 登出的 mutation 字段（本域无 query 段——me / my_phone 归
  用户自助面留 schema）；类型在 `Auth.Types`，域内 helper 在 `Auth.Helpers`。
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
        key_path: [:login],
        normalize: &Cgc2046.Accounts.WebAuthFlow.normalize_login/1
      )

      resolve(fn _, %{login: login, password: password}, _ ->
        # 分流：含 @ → email；否则按手机号归一化（同号不同写法命中同一 User 与同一限流 key）
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
                # 非法手机号格式：直接走 email 分支让其产出既有的统一认证失败错误
                # （防枚举语义不变，不新增格式错误出口）
                Cgc2046.Accounts.User
                |> Ash.Query.for_read(:sign_in_with_password, %{email: login, password: password})
            end
          end

        try do
          case Ash.read(query) do
            {:ok, [user]} ->
              {:ok,
               %{
                 id: user.id,
                 email: user.email,
                 is_platform_admin: user.is_platform_admin,
                 # token 仅用于 middleware 传递到 before_send，不暴露在响应中
                 __token__: user.__metadata__[:token]
               }}

            {:error, _error} ->
              {:error, message: "Invalid email or password", code: "authentication_failed"}
          end
        rescue
          _ -> {:error, message: "Invalid email or password", code: "authentication_failed"}
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

    @desc "请求发送密码重置邮件（无论邮箱是否存在都返回统一成功结果）"
    field :request_password_reset, :request_password_reset_result do
      arg(:email, non_null(:string))

      middleware(
        Cgc2046Web.Plugs.RateLimit,
        key_path: [:email],
        normalize: &Cgc2046.Accounts.WebAuthFlow.normalize_email/1
      )

      resolve(fn _, %{email: email}, %{context: context} ->
        email = Cgc2046.Accounts.WebAuthFlow.normalize_email(email)

        case Cgc2046.Accounts.WebAuthFlow.check_password_reset_request_limits(context, email) do
          :ok ->
            strategy = AshAuthentication.Info.strategy!(Cgc2046.Accounts.User, :password)

            _ =
              AshAuthentication.Strategy.action(
                strategy,
                :reset_request,
                %{"email" => email}
              )

            {:ok, %{sent: true}}

          :error ->
            {:error, message: "Too many requests. Try again later.", code: "rate_limited"}
        end
      end)
    end

    @desc "使用一次性密码重置 token 设置新密码"
    field :reset_password, :reset_password_result do
      arg(:reset_token, non_null(:string))
      arg(:password, non_null(:string))

      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:reset_token])

      resolve(fn _, %{reset_token: reset_token, password: password}, %{context: context} ->
        params = %{
          "reset_token" => reset_token,
          "password" => password
        }

        strategy = AshAuthentication.Info.strategy!(Cgc2046.Accounts.User, :password)

        try do
          case AshAuthentication.Strategy.action(strategy, :reset, params) do
            {:ok, _user} ->
              {:ok, %{ok: true}}

            {:error, error} ->
              Cgc2046.Accounts.WebAuthFlow.classify_password_reset_error(error, context)

            other ->
              Cgc2046.Accounts.WebAuthFlow.report_password_reset_failure(other)
          end
        rescue
          error ->
            Cgc2046.Accounts.WebAuthFlow.report_password_reset_failure(error)
        catch
          kind, reason ->
            Cgc2046.Accounts.WebAuthFlow.report_password_reset_failure({kind, reason})
        end
      end)
    end

    @desc "小程序平台一键登录（N1，Phase 1）：code2session + 平台手机号锚定统一身份，token 经 httpOnly cookie 交付"
    field :sign_in_with_platform, :sign_in_with_platform_result do
      arg(:platform, non_null(:string))
      arg(:code, non_null(:string))
      arg(:phone_code, :string)
      arg(:encrypted_data, :string)
      arg(:iv, :string)

      # #930：IP 维度只留宽松天花板（线下活动同一 WiFi / CGNAT 多人共享 IP）；
      # getPhoneNumber 计费防刷改按 openid 计（SignInPreparation，code2session 之后、换手机号之前）
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:platform], limit: :platform_sign_in_ip)

      resolve(fn _, %{platform: platform, code: code} = args, _ ->
        # phone_code/encrypted_data/iv 可空（phone_code 或 encrypted_data+iv 二选一，
        # 由 SignInPreparation.fetch_phone 校验组合）；缺键时 Map.get 得 nil 透传。
        query =
          Cgc2046.Accounts.User
          |> Ash.Query.for_read(:sign_in_with_miniprogram, %{
            platform: platform,
            code: code,
            phone_code: Map.get(args, :phone_code),
            encrypted_data: Map.get(args, :encrypted_data),
            iv: Map.get(args, :iv)
          })

        try do
          case Ash.read(query) do
            {:ok, [user]} ->
              {:ok,
               %{
                 id: user.id,
                 email: user.email,
                 is_platform_admin: user.is_platform_admin,
                 # token 仅用于 middleware 传递到 before_send，不暴露在响应中
                 __token__: user.__metadata__[:token]
               }}

            {:error, error} ->
              if platform_sign_in_rate_limited?(error),
                do:
                  {:error, message: "Too many requests. Try again later.", code: "rate_limited"},
                else: {:error, message: "Platform sign in failed", code: "authentication_failed"}
          end
        rescue
          _ -> {:error, message: "Platform sign in failed", code: "authentication_failed"}
        catch
          # Elixir rescue 不抓 exit（如依赖进程缺失 noproc）——缺此分支则
          # 登录失败穿透至 Absinthe/Plug 500 且无统一文案，防枚举语义被绕过。
          :exit, _ ->
            {:error, message: "Platform sign in failed", code: "authentication_failed"}
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

    @desc "小程序回访静默登录（#930）：只用平台登录凭证 code——已绑定本平台身份（openid）的账号直接签发会话，不走计费的手机号授权；本平台还没有绑定身份（首次登录）→ platform_identity_not_found，前端退回手机号登录。token 同 signInWithPlatform 经 httpOnly cookie 交付"
    field :sign_in_with_platform_identity, :sign_in_with_platform_result do
      arg(:platform, non_null(:string))
      arg(:code, non_null(:string))

      # 与手机号登录共用 IP 天花板（同 key_path → 同一个桶）；openid 桶在 PlatformIdentitySignIn 内共用
      middleware(Cgc2046Web.Plugs.RateLimit, key_path: [:platform], limit: :platform_sign_in_ip)

      resolve(fn _, %{platform: platform, code: code}, %{context: context} ->
        try do
          case Cgc2046.Accounts.PlatformIdentitySignIn.sign_in(platform, code, context) do
            {:ok, user} ->
              {:ok,
               %{
                 id: user.id,
                 email: user.email,
                 is_platform_admin: user.is_platform_admin,
                 # token 仅用于 middleware 传递到 before_send，不暴露在响应中
                 __token__: user.__metadata__[:token]
               }}

            # 本平台还没绑定身份：如实告知（openid 来自请求者自己的 code，不泄露他人信息）
            {:error, :identity_not_found} ->
              {:error,
               message: "No platform identity bound yet", code: "platform_identity_not_found"}

            {:error, :rate_limited} ->
              {:error, message: "Too many requests. Try again later.", code: "rate_limited"}

            {:error, reason} ->
              Logger.warning("[platform identity sign_in] failed: #{inspect(reason)}")
              {:error, message: "Platform sign in failed", code: "authentication_failed"}
          end
        rescue
          _ -> {:error, message: "Platform sign in failed", code: "authentication_failed"}
        catch
          # 同 signInWithPlatform：rescue 不抓 exit（依赖进程缺失 noproc），缺此分支会穿透成 500
          :exit, _ ->
            {:error, message: "Platform sign in failed", code: "authentication_failed"}
        end
      end)

      # 同 signInWithPlatform：token 经 context 交给 before_send 写 httpOnly cookie
      middleware(fn res, _ ->
        case res.value do
          %{__token__: token} when is_binary(token) ->
            %{res | context: Map.put(res.context, :cgc_auth_token, token)}

          _ ->
            res
        end
      end)
    end

    @desc "登出：服务端撤销当前 token 并清除 httpOnly cookie（token 被偷也无法重放）"
    field :sign_out, :string do
      resolve(fn _, _, _ ->
        {:ok, "signed_out"}
      end)

      middleware(fn res, _ ->
        revoke_bearer_token(res.context)
        %{res | context: Map.put(res.context, :cgc_clear_token, true)}
      end)
    end
  end
end
