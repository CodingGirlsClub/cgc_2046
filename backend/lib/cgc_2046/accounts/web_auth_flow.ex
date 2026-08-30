defmodule Cgc2046.Accounts.WebAuthFlow do
  @moduledoc """
  web GraphQL 注册/登录入口编排层（ADR-0010 批次 3：自 Cgc2046Web.GraphqlSchema 抽离）。

  收容 signUpWithPhone / updateMyPhone / wechatLoginStart / requestPasswordReset /
  resetPassword 等 web resolver 的领域编排：固定窗口 ETS 限流族、注册建号 + 默认
  工作台入座、换绑、微信扫码发起、密码重置错误分类与 telemetry。

  与 Cgc2046.Accounts.SignInFlow 的分工：SignInFlow 是跨端共享的登录原子步骤
  （find-or-create / token 签发 / 吊销 / 入座），被 web 与小程序等多入口复用；
  WebAuthFlow 是 web resolver 的入口编排——resolver 只做参数解包，此处完成
  限流 → 领域动作 → GraphQL 形状结果（payload / message+code）的直通返回。
  """

  require Logger
  require Ash.Query

  # ── 手机验证码（plan 002 U3）───────────────────────────────────────────

  # 发码四窗口限流（phone 1/60s + 5/1h + 20/1d，IP 30/1d）；固定窗口 ETS
  # 同款（密码重置双限流先例），多实例连调。
  def check_phone_code_request_limits(context, phone) do
    ip = remote_ip(context)

    phone_key = Cgc2046Web.Plugs.RateLimit.build_key("rate:phone-code:phone", phone)

    windows = [
      {"#{phone_key}:1m", 60, 1},
      {"#{phone_key}:1h", 3_600, 5},
      {"#{phone_key}:1d", 86_400, 20},
      {"rate:phone-code:ip:1d:#{ip}", 86_400, 30}
    ]

    windows
    |> Enum.reduce_while(:ok, fn {key, window, max}, :ok ->
      case Cgc2046Web.Plugs.RateLimit.check(key, window_seconds: window, max_attempts: max) do
        :ok -> {:cont, :ok}
        :error -> {:halt, {:error, :rate_limited}}
      end
    end)
  end

  # 验码双限流（phone 5/15min，IP 20/15min）
  def check_phone_code_verify_limits(context, phone) do
    ip = remote_ip(context)

    windows = [
      {Cgc2046Web.Plugs.RateLimit.build_key("rate:phone-code-verify:phone", phone), 900, 5},
      {"rate:phone-code-verify:ip:#{ip}", 900, 20}
    ]

    windows
    |> Enum.reduce_while(:ok, fn {key, window, max}, :ok ->
      case Cgc2046Web.Plugs.RateLimit.check(key, window_seconds: window, max_attempts: max) do
        :ok -> {:cont, :ok}
        :error -> {:halt, {:error, :rate_limited}}
      end
    end)
  end

  # 手机号注册（手机号注册）：验码(purpose :register) → 已存在则
  # phone_already_registered（此时手机所有权已证明，无枚举风险）→ 建号
  # （register_with_password_phone，email 可空）→ 自动入座 2046 → 签 JWT。
  def sign_up_with_phone(phone, code, password, context) do
    # 无副作用校验前置（codex 评审 #3/#6）：bcrypt 只取前 72 字节——先于验码
    # 消费拒绝越界密码，避免「短密码烧码后重试要重新收码」与 72 字节截断互认。
    with :ok <- validate_register_password(password),
         :ok <- Cgc2046.Accounts.PhoneVerificationCode.consume_valid(phone, code, :register),
         :ok <- ensure_phone_unregistered(phone) do
      changeset =
        Cgc2046.Accounts.User
        |> Ash.Changeset.for_create(:register_with_password_phone, %{
          phone: phone,
          password: password
        })

      case Ash.create(changeset) do
        {:ok, user} ->
          # ADR-0004 §3.5：同 signUp——入座失败降级不阻断注册
          try do
            case Cgc2046.Accounts.MembershipContext.admit_to_default_workspace(user.id) do
              {:ok, _} ->
                :ok

              {:error, reason} ->
                Logger.warning("[signUpWithPhone] enroll failed: #{inspect(reason)}")
            end
          rescue
            error ->
              Logger.warning("[signUpWithPhone] enroll raised: #{Exception.message(error)}")
          end

          {:ok,
           %{
             result: %{id: user.id, email: user.email, is_platform_admin: user.is_platform_admin},
             errors: [],
             __token__: user.__metadata__[:token]
           }}

        {:error, %Ash.Error.Invalid{} = error} ->
          {:ok,
           %{
             result: nil,
             errors: to_ash_graphql_errors(error, context, :register_with_password_phone),
             __token__: nil
           }}

        {:error, reason} ->
          Logger.warning("[signUpWithPhone] create failed: #{inspect(reason)}")
          {:ok, phone_registration_failed_payload()}
      end
    else
      {:error, :invalid_password} ->
        {:error, message: "Password must be 8 to 72 bytes", code: "invalid_password"}

      {:error, :invalid_code} ->
        {:error, message: "Invalid or expired code", code: "invalid_or_expired_code"}

      {:error, :code_not_available} ->
        {:error, message: "Invalid or expired code", code: "invalid_or_expired_code"}

      {:error, :phone_taken} ->
        {:error, message: "Phone number already registered", code: "phone_already_registered"}

      {:error, reason} ->
        # ensure_phone_unregistered 的 DB 读失败等未知错误：受控失败 payload
        # （旧 signUp 的 rescue 降级语义），不抛 WithClauseError 变顶层 500。
        Logger.warning("[signUpWithPhone] pre-check failed: #{inspect(reason)}")
        {:ok, phone_registration_failed_payload()}
    end
  end

  # 8..72 字节（byte_size，非字符数；bcrypt 上限 72）。GraphQL 层前置，
  # 与 register_with_password_phone action 的 min 8 校验双保险。
  defp validate_register_password(password) when is_binary(password) do
    size = byte_size(password)

    if size >= 8 and size <= 72,
      do: :ok,
      else: {:error, :invalid_password}
  end

  defp ensure_phone_unregistered(phone) do
    case Cgc2046.Accounts.User
         |> Ash.Query.filter(phone == ^phone)
         |> Ash.read(authorize?: false) do
      {:ok, []} -> :ok
      {:ok, _} -> {:error, :phone_taken}
      {:error, reason} -> {:error, reason}
    end
  end

  # 换绑编排（updateMyPhone，验码已通过）：新号 == 现号幂等成功；被他人占用 →
  # phone_already_registered（短信所有权已证明，无枚举顾虑）；否则走
  # :update_phone 原子更新（并发占用由 unique_phone 部分唯一索引兜底）。
  def update_my_phone(actor, phone, context) do
    if actor.phone == phone do
      load_profile(actor, actor, context, :update_phone)
    else
      case ensure_phone_unregistered(phone) do
        :ok ->
          case Ash.update(actor, %{phone: phone}, action: :update_phone, actor: actor) do
            {:ok, user} ->
              load_profile(user, actor, context, :update_phone)

            {:error, error} ->
              {:error, to_ash_graphql_errors(error, context, :update_phone)}
          end

        {:error, :phone_taken} ->
          {:error, message: "Phone number already registered", code: "phone_already_registered"}

        {:error, reason} ->
          # 占用预检 DB 读失败：受控失败（同 signUpWithPhone pre-check 语义），
          # 复用 Ash 错误映射，不新增 resolver 字面量 code。
          Logger.warning("[updateMyPhone] pre-check failed: #{inspect(reason)}")
          {:error, to_ash_graphql_errors(reason, context, :update_phone)}
      end
    end
  end

  defp phone_registration_failed_payload do
    %{
      result: nil,
      errors: [%{message: "Registration failed. Please try again.", code: "registration_failed"}],
      __token__: nil
    }
  end

  # ── 微信扫码登录（plan 002 U4）─────────────────────────────────────────

  def check_wechat_login_start_limits(context) do
    check_single_limit("rate:wechat-login-start:ip:#{remote_ip(context)}", 900, 20)
  end

  def check_wechat_callback_limits(context) do
    check_single_limit("rate:wechat-callback:ip:#{remote_ip(context)}", 900, 20)
  end

  def check_wechat_bind_limits(_context, phone) do
    check_single_limit(
      Cgc2046Web.Plugs.RateLimit.build_key("rate:wechat-bind:phone", phone),
      900,
      5
    )
  end

  defp check_single_limit(key, window, max) do
    case Cgc2046Web.Plugs.RateLimit.check(key, window_seconds: window, max_attempts: max) do
      :ok -> :ok
      :error -> {:error, :rate_limited}
    end
  end

  def summarize_wechat_sign_in_failure(reason) when is_atom(reason), do: reason

  def summarize_wechat_sign_in_failure({:wechat_web_code_rejected, errcode})
      when is_integer(errcode),
      do: {:wechat_web_code_rejected, errcode}

  def summarize_wechat_sign_in_failure({:wechat_web_bad_response, status})
      when is_integer(status),
      do: {:wechat_web_bad_response, status}

  def summarize_wechat_sign_in_failure({:wechat_web_network, _reason}),
    do: :wechat_web_network

  def summarize_wechat_sign_in_failure({tag, _detail}) when is_atom(tag), do: tag
  def summarize_wechat_sign_in_failure({tag, _detail, _context}) when is_atom(tag), do: tag
  def summarize_wechat_sign_in_failure(_reason), do: :internal_error

  def start_wechat_login(next) do
    # next 由 state 无关的 URL 参数透传(plan 002):嵌入 redirect_uri,微信回调原样带回;
    # 开放跳转防护在 callback 页 resolveNextTarget 同源校验,此处仅透传。
    base = Application.fetch_env!(:cgc_2046, :web_base_url) <> "/login/wechat-callback"

    redirect_uri =
      case next do
        value when is_binary(value) and value != "" ->
          # 不预编码:qr_connect_url 的 encode_query 对整个 redirect_uri 统一编码一次
          base <> "?next=" <> value

        _ ->
          base
      end

    case Cgc2046.Accounts.WechatLoginTicket.issue() do
      {:ok, %{state: state, expires_at: expires_at}} ->
        case Cgc2046.Integrations.Wechat.WebOAuth.qr_connect_url(redirect_uri, state) do
          url when is_binary(url) ->
            expires_in = max(DateTime.diff(expires_at, DateTime.utc_now()), 0)
            {:ok, %{qr_url: url, state: state, expires_in_seconds: expires_in}}

          {:error, _reason} ->
            {:error, message: "WeChat login is unavailable", code: "wechat_login_unavailable"}
        end

      {:error, _reason} ->
        {:error, message: "WeChat login is unavailable", code: "wechat_login_unavailable"}
    end
  end

  # ── 密码重置 ──────────────────────────────────────────────────────────

  def check_password_reset_request_limits(context, email) do
    email_key = Cgc2046Web.Plugs.RateLimit.build_key("rate:password-reset:email", email)

    ip_key =
      Cgc2046Web.Plugs.RateLimit.build_key(
        "rate:password-reset:ip",
        remote_ip(context)
      )

    with :ok <-
           Cgc2046Web.Plugs.RateLimit.check(
             email_key,
             window_seconds: 3_600
           ),
         :ok <-
           Cgc2046Web.Plugs.RateLimit.check(
             ip_key,
             window_seconds: 3_600,
             max_attempts: 20
           ) do
      :ok
    end
  end

  @doc false
  def password_reset_failure_telemetry(reason) do
    if revoke_failure?(reason) do
      {[:cgc2046, :password_reset, :revoke], :revoke_failed}
    else
      {[:cgc2046, :password_reset, :reset], :reset_failed}
    end
  end

  defp revoke_failure?(%Cgc2046.Accounts.PasswordResetRevocationError{}), do: true

  defp revoke_failure?(%{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &revoke_failure?/1)
  end

  defp revoke_failure?(%{value: value}), do: revoke_failure?(value)
  defp revoke_failure?(%{error: error}), do: revoke_failure?(error)
  defp revoke_failure?(%{reason: reason}), do: revoke_failure?(reason)

  defp revoke_failure?(list) when is_list(list) do
    Enum.any?(list, &revoke_failure?/1)
  end

  defp revoke_failure?(_reason), do: false

  def classify_password_reset_error(error, _context)
      when is_struct(error, AshAuthentication.Errors.InvalidToken) do
    {:error, message: "链接无效或已过期", code: "invalid_reset_token"}
  end

  def classify_password_reset_error(%Ash.Error.Invalid{} = error, context) do
    {:error, to_ash_graphql_errors(error, context, :password_reset_with_password)}
  end

  def classify_password_reset_error(error, _context), do: report_password_reset_failure(error)

  def report_password_reset_failure(reason) do
    {telemetry_event, reason_category} = password_reset_failure_telemetry(reason)

    Logger.warning("password reset failed reason=#{reason_category}")

    :telemetry.execute(
      telemetry_event,
      %{count: 1},
      %{reason: reason_category, email: nil}
    )

    {:error, message: "密码重置失败，请稍后重试", code: "password_reset_failed"}
  end

  # ── 共享小工具（最小集合复制，判定见 ADR-0010 批次 3 记录）────────────────

  defp remote_ip(%{conn: %{remote_ip: ip}}), do: ip |> :inet.ntoa() |> to_string()
  defp remote_ip(_context), do: "unknown"

  # Ash action 错误 → AshGraphql.Error 结构化顶层 error（message/code/fields）。
  # 与 Cgc2046Web.GraphqlSchema.to_ash_graphql_errors/5 同映射；本模块消费方均属
  # Accounts 域、资源 User，固定默认值（schema 侧的显式 resource/domain 形参此副本不需要）。
  defp to_ash_graphql_errors(error, context, action) do
    error
    |> AshGraphql.Errors.to_errors(context, Cgc2046.Accounts, Cgc2046.Accounts.User, action)
    |> Enum.map(&Map.take(&1, [:message, :code, :fields]))
  end

  # 个人资料加载：member_number/joined_at 为计算属性，更新后需显式加载。
  # 与 Cgc2046Web.GraphqlSchema.load_profile/4 同语义（updateMyPhone 专用副本）。
  defp load_profile(user, actor, context, action) do
    case Ash.load(user, [:member_number, :joined_at],
           actor: actor,
           domain: Cgc2046.Accounts
         ) do
      {:ok, loaded} ->
        {:ok, loaded}

      {:error, error} ->
        {:error, to_ash_graphql_errors(error, context, action)}
    end
  end
end
