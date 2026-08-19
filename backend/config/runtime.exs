import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/cgc_2046 start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :cgc_2046, Cgc2046Web.Endpoint, server: true
end

config :cgc_2046, Cgc2046Web.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# CORS origin: comma-separated list from env; defaults to localhost:3000 for dev/test.
# In production, CORS_ORIGIN is required — deployment must set it to the actual
# frontend origin (e.g., "https://app.example.com").
cors_origin =
  if config_env() == :prod do
    System.get_env("CORS_ORIGIN") ||
      raise """
      environment variable CORS_ORIGIN is missing.
      Set it to the frontend origin, e.g. "https://app.example.com".
      For multiple origins, use a comma-separated list.
      """
  else
    System.get_env("CORS_ORIGIN", "http://localhost:3000")
  end

config :cgc_2046,
       :cors_origin,
       cors_origin
       |> String.split(",", trim: true)
       |> Enum.map(&String.trim/1)

# Password reset links are built from this runtime-configured origin. Dev/test
# keep a localhost default; production must use HTTPS so reset tokens never
# travel over a clear-text link.
web_base_url =
  if config_env() == :prod do
    System.get_env("WEB_BASE_URL") ||
      raise """
      environment variable WEB_BASE_URL is missing.
      Set it to the public HTTPS web origin, e.g. "https://app.example.com".
      """
  else
    System.get_env("WEB_BASE_URL", "http://localhost:3000")
  end

if config_env() == :prod and URI.parse(web_base_url).scheme != "https" do
  raise """
  WEB_BASE_URL must use https in production.
  Set it to the public HTTPS web origin, e.g. "https://app.example.com".
  """
end

config :cgc_2046, :web_base_url, web_base_url

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :cgc_2046, Cgc2046.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :cgc_2046, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :cgc_2046, Cgc2046Web.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # JWT signing secret for ash_authentication. MUST be provided in prod
  # (never commit a real secret).
  token_signing_secret =
    System.get_env("TOKEN_SIGNING_SECRET") ||
      raise """
      environment variable TOKEN_SIGNING_SECRET is missing.
      Generate a strong random value, e.g. `mix phx.gen.secret`.
      """

  config :cgc_2046, :token_signing_secret, token_signing_secret

  # 小程序平台凭证（Phase 1）。prod 必须经环境变量提供，缺失即启动失败；
  # 任何环境下都不把真实 appid/secret 提交进 git。
  miniprogram_platforms = %{
    wechat: %{
      appid: System.fetch_env!("WECHAT_MP_APPID"),
      secret: System.fetch_env!("WECHAT_MP_SECRET")
    },
    tt: %{
      appid: System.fetch_env!("TT_MP_APPID"),
      secret: System.fetch_env!("TT_MP_SECRET")
    },
    xhs: %{
      appid: System.fetch_env!("XHS_MP_APPID"),
      secret: System.fetch_env!("XHS_MP_SECRET"),
      qrcode_path: System.fetch_env!("XHS_MP_QRCODE_PATH"),
      notification_path: System.fetch_env!("XHS_MP_NOTIFICATION_PATH")
    }
  }

  config :cgc_2046, :miniprogram_platforms, miniprogram_platforms

  config :cgc_2046, :miniprogram_templates, %{
    wechat: %{
      "approval_result" => System.fetch_env!("WECHAT_MP_TEMPLATE_APPROVAL_RESULT"),
      "approval_reminder" => System.fetch_env!("WECHAT_MP_TEMPLATE_APPROVAL_REMINDER"),
      "enrollment_submitted" => System.fetch_env!("WECHAT_MP_TEMPLATE_ENROLLMENT_SUBMITTED"),
      "enrollment_completed" => System.fetch_env!("WECHAT_MP_TEMPLATE_ENROLLMENT_COMPLETED"),
      "speaker_accepted" => System.fetch_env!("WECHAT_MP_TEMPLATE_SPEAKER_ACCEPTED"),
      "speaker_completed" => System.fetch_env!("WECHAT_MP_TEMPLATE_SPEAKER_COMPLETED"),
      "learning_stagnation" => System.fetch_env!("WECHAT_MP_TEMPLATE_LEARNING_STAGNATION"),
      # 缴费闭环三模板（U10/KTD8 定稿）
      "payment_succeeded" => System.fetch_env!("WECHAT_MP_TEMPLATE_PAYMENT_SUCCEEDED"),
      "refund_succeeded" => System.fetch_env!("WECHAT_MP_TEMPLATE_REFUND_SUCCEEDED"),
      "refund_failed" => System.fetch_env!("WECHAT_MP_TEMPLATE_REFUND_FAILED")
    },
    tt: %{
      "approval_result" => System.fetch_env!("TT_MP_TEMPLATE_APPROVAL_RESULT"),
      "approval_reminder" => System.fetch_env!("TT_MP_TEMPLATE_APPROVAL_REMINDER"),
      "enrollment_submitted" => System.fetch_env!("TT_MP_TEMPLATE_ENROLLMENT_SUBMITTED"),
      "enrollment_completed" => System.fetch_env!("TT_MP_TEMPLATE_ENROLLMENT_COMPLETED"),
      "speaker_accepted" => System.fetch_env!("TT_MP_TEMPLATE_SPEAKER_ACCEPTED"),
      "speaker_completed" => System.fetch_env!("TT_MP_TEMPLATE_SPEAKER_COMPLETED"),
      "learning_stagnation" => System.fetch_env!("TT_MP_TEMPLATE_LEARNING_STAGNATION"),
      # 缴费闭环三模板（U10/KTD8 定稿）
      "payment_succeeded" => System.fetch_env!("TT_MP_TEMPLATE_PAYMENT_SUCCEEDED"),
      "refund_succeeded" => System.fetch_env!("TT_MP_TEMPLATE_REFUND_SUCCEEDED"),
      "refund_failed" => System.fetch_env!("TT_MP_TEMPLATE_REFUND_FAILED")
    },
    xhs: %{
      "approval_result" => System.fetch_env!("XHS_MP_TEMPLATE_APPROVAL_RESULT"),
      "approval_reminder" => System.fetch_env!("XHS_MP_TEMPLATE_APPROVAL_REMINDER"),
      "enrollment_submitted" => System.fetch_env!("XHS_MP_TEMPLATE_ENROLLMENT_SUBMITTED"),
      "enrollment_completed" => System.fetch_env!("XHS_MP_TEMPLATE_ENROLLMENT_COMPLETED"),
      "speaker_accepted" => System.fetch_env!("XHS_MP_TEMPLATE_SPEAKER_ACCEPTED"),
      "speaker_completed" => System.fetch_env!("XHS_MP_TEMPLATE_SPEAKER_COMPLETED"),
      "learning_stagnation" => System.fetch_env!("XHS_MP_TEMPLATE_LEARNING_STAGNATION"),
      # 缴费闭环三模板（U10/KTD8 定稿）
      "payment_succeeded" => System.fetch_env!("XHS_MP_TEMPLATE_PAYMENT_SUCCEEDED"),
      "refund_succeeded" => System.fetch_env!("XHS_MP_TEMPLATE_REFUND_SUCCEEDED"),
      "refund_failed" => System.fetch_env!("XHS_MP_TEMPLATE_REFUND_FAILED")
    }
  }

  # SendCloud is the production mail transport. Keep every required value in
  # runtime configuration so a release cannot start with a partially configured
  # reset-mail path.
  sendcloud_api_user =
    System.get_env("SENDCLOUD_API_USER") ||
      raise """
      environment variable SENDCLOUD_API_USER is missing.
      Set it to the SendCloud API user for regular mail sending.
      """

  sendcloud_api_key =
    System.get_env("SENDCLOUD_API_KEY") ||
      raise """
      environment variable SENDCLOUD_API_KEY is missing.
      Set it to the SendCloud API key for regular mail sending.
      """

  sendcloud_from =
    System.get_env("SENDCLOUD_FROM") ||
      raise """
      environment variable SENDCLOUD_FROM is missing.
      Set it to the verified SendCloud sender address.
      """

  sendcloud_from_name =
    System.get_env("SENDCLOUD_FROM_NAME") ||
      raise """
      environment variable SENDCLOUD_FROM_NAME is missing.
      Set it to the display name for password reset emails.
      """

  config :cgc_2046, Cgc2046.Mailer,
    adapter: Cgc2046.SwooshAdapters.SendCloud,
    api_user: sendcloud_api_user,
    api_key: sendcloud_api_key,
    from: sendcloud_from,
    from_name: sendcloud_from_name

  # SendCloud SMS（plan 002 U3）：与邮件同款 prod 硬门禁——缺凭证不允许启动
  # （发码路径是登录能力，半配置上线 = 静默坏登录）。
  sendcloud_sms_user =
    System.get_env("SENDCLOUD_SMS_USER") ||
      raise """
      environment variable SENDCLOUD_SMS_USER is missing.
      Set it to the SendCloud SMS user (短信语音 → 发送授权).
      """

  sendcloud_sms_key =
    System.get_env("SENDCLOUD_SMS_KEY") ||
      raise """
      environment variable SENDCLOUD_SMS_KEY is missing.
      Set it to the SendCloud SMS key.
      """

  sendcloud_sms_template_id =
    System.get_env("SENDCLOUD_SMS_TEMPLATE_ID") ||
      raise """
      environment variable SENDCLOUD_SMS_TEMPLATE_ID is missing.
      Set it to the approved verification-code template id.
      """

  config :cgc_2046,
    sms_sendcloud: [
      sms_user: sendcloud_sms_user,
      sms_key: sendcloud_sms_key,
      template_id: sendcloud_sms_template_id
    ]

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :cgc_2046, Cgc2046Web.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :cgc_2046, Cgc2046Web.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :cgc_2046, Cgc2046.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.

  # 缴费闭环 U4（KTD7）：渠道密钥同 SendCloud 模式——环境变量注入，不进 git。
  # 与 SendCloud 不同处：真实小额验收上线前，密钥允许缺席（adapter 返回
  # :provider_not_configured，boot 不崩），验收后补齐环境变量即启用。
  config :cgc_2046,
    wechat_pay: [
      mch_id: System.get_env("WECHAT_PAY_MCH_ID"),
      appid: System.get_env("WECHAT_PAY_APPID"),
      api_v3_key: System.get_env("WECHAT_PAY_API_V3_KEY"),
      # SDK build_client 硬性必需键（plan 007）：与 v3 key 同为可选语义——缺席则
      # adapter 门禁短路 provider_not_configured，boot 不崩。
      api_secret_v2_key: System.get_env("WECHAT_PAY_API_V2_KEY"),
      client_serial_no: System.get_env("WECHAT_PAY_CLIENT_SERIAL_NO"),
      client_private_key: System.get_env("WECHAT_PAY_CLIENT_PRIVATE_KEY"),
      webhook_base_url: System.get_env("PAYMENTS_WEBHOOK_BASE_URL")
    ],
    alipay_pay: [
      app_id: System.get_env("ALIPAY_APP_ID"),
      private_key: System.get_env("ALIPAY_PRIVATE_KEY"),
      public_key: System.get_env("ALIPAY_PUBLIC_KEY"),
      webhook_base_url: System.get_env("PAYMENTS_WEBHOOK_BASE_URL"),
      return_url: System.get_env("ALIPAY_RETURN_URL"),
      sandbox: System.get_env("ALIPAY_SANDBOX") == "true"
    ]
end
