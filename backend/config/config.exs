# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :cgc_2046,
  ecto_repos: [Cgc2046.Repo],
  ash_domains: [Cgc2046.Api, Cgc2046.GlobalApi, Cgc2046.Mcp, Cgc2046.Payments],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :cgc_2046, AshPostgres,
  repo: Cgc2046.Repo,
  migrations: true

# Configure the endpoint
config :cgc_2046, Cgc2046Web.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: Cgc2046Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: Cgc2046.PubSub,
  live_view: [signing_salt: "HG0TqgPo"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :cgc_2046, Cgc2046.Mailer, adapter: Swoosh.Adapters.Local

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# JWT signing secret for ash_authentication.
# Dev/test use a static dev-only value; prod MUST override via TOKEN_SIGNING_SECRET
# in config/runtime.exs (never commit a real secret).
config :cgc_2046, :token_signing_secret, "dev-only-token-signing-secret-change-me"

# 小程序平台凭证（Phase 1：wechat/tt/xhs 的 code2session）。
# 此处为 dev/test dummy 值；prod 由 config/runtime.exs 经环境变量注入（不进 git）。
config :cgc_2046, :miniprogram_platforms, %{
  wechat: %{appid: "dev-wechat-appid", secret: "dev-wechat-secret"},
  tt: %{appid: "dev-tt-appid", secret: "dev-tt-secret"},
  xhs: %{
    appid: "dev-xhs-appid",
    secret: "dev-xhs-secret",
    qrcode_path: "/api/rmp/qrcode/unlimited",
    notification_path: "/api/rmp/subscribe/send"
  }
}

# 订阅消息模板 registry：dev/test 仅占位值；prod 由 runtime.exs 注入真实模板 ID。
config :cgc_2046, :miniprogram_templates, %{
  wechat: %{
    "approval_result" => "dev-wechat-approval-result",
    "approval_reminder" => "dev-wechat-approval-reminder",
    "enrollment_submitted" => "dev-wechat-enrollment-submitted",
    "enrollment_completed" => "dev-wechat-enrollment-completed",
    "speaker_accepted" => "dev-wechat-speaker-accepted",
    "speaker_completed" => "dev-wechat-speaker-completed",
    "learning_stagnation" => "dev-wechat-learning-stagnation",
    # 缴费闭环三模板（U10/KTD8 定稿）
    "payment_succeeded" => "dev-wechat-payment-succeeded",
    "refund_succeeded" => "dev-wechat-refund-succeeded",
    "refund_failed" => "dev-wechat-refund-failed"
  },
  tt: %{
    "approval_result" => "dev-tt-approval-result",
    "approval_reminder" => "dev-tt-approval-reminder",
    "enrollment_submitted" => "dev-tt-enrollment-submitted",
    "enrollment_completed" => "dev-tt-enrollment-completed",
    "speaker_accepted" => "dev-tt-speaker-accepted",
    "speaker_completed" => "dev-tt-speaker-completed",
    "learning_stagnation" => "dev-tt-learning-stagnation",
    # 缴费闭环三模板（U10/KTD8 定稿）
    "payment_succeeded" => "dev-tt-payment-succeeded",
    "refund_succeeded" => "dev-tt-refund-succeeded",
    "refund_failed" => "dev-tt-refund-failed"
  },
  xhs: %{
    "approval_result" => "dev-xhs-approval-result",
    "approval_reminder" => "dev-xhs-approval-reminder",
    "enrollment_submitted" => "dev-xhs-enrollment-submitted",
    "enrollment_completed" => "dev-xhs-enrollment-completed",
    "speaker_accepted" => "dev-xhs-speaker-accepted",
    "speaker_completed" => "dev-xhs-speaker-completed",
    "learning_stagnation" => "dev-xhs-learning-stagnation",
    # 缴费闭环三模板（U10/KTD8 定稿）
    "payment_succeeded" => "dev-xhs-payment-succeeded",
    "refund_succeeded" => "dev-xhs-refund-succeeded",
    "refund_failed" => "dev-xhs-refund-failed"
  }
}

# SendCloud SMS（plan 002 U3）：默认未配置（nil）。未配置时 dev 发码走 Logger
# 出码（deliver_phone_code 分支），本地可测；prod 由 runtime.exs 经环境变量注入
# （SENDCLOUD_SMS_USER/KEY/TEMPLATE_ID，缺则 raise）；test 在 test.exs 显式给
# stub 值（Req.Test 拦截，configured? 走真实 deliver 分支）。
config :cgc_2046,
  sms_sendcloud: [
    sms_user: nil,
    sms_key: nil,
    template_id: nil
  ]

# 微信开放平台网站应用扫码登录（plan 002 U4）：默认未配置（nil）——
# wechatLoginStart 门禁 wechat_login_unavailable，其余登录方式不受影响。
# prod/dev 由 runtime.exs 读 WECHAT_WEB_APPID/SECRET（可选）；test 在 test.exs
# 显式给 stub 值。
config :cgc_2046,
  wechat_web: [
    appid: nil,
    secret: nil
  ]

# 0C：Oban（PG-backed，跑在现有 Phoenix 应用内，无新服务）。
# - maintenance 队列：审批超时扫描（expiry）+ 48h 提醒（reminder）共用，并发 5 足够
#   （两者均为轻量查询 + 少量 Ash update）。
# - Cron：expiry 每 5 分钟（审批过期落库的及时性与 DB 压力的折中）；
#   reminder 每小时（48h 窗口下小时级粒度足够，窗口内幂等去重兜底）。
# - Pruner：oban_jobs 保留 7 天，防表无限膨胀。
# 测试环境在 test.exs 以 testing: :manual 覆盖（Oban 自动禁用 queues/plugins/cron）。
# payments 队列（缴费闭环 U6/U7）：回调落账 + 退款——资金链路独立于维护/通知，
# 并发 10 防回调尖峰堆积（每 job = 一次渠道查单 + 少量 CAS）。
config :cgc_2046, Oban,
  repo: Cgc2046.Repo,
  queues: [maintenance: 5, notifications: 10, payments: 10],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/5 * * * *", Cgc2046.Workers.ApprovalExpiryWorker},
       {"*/5 * * * *", Cgc2046.Workers.EventLifecycleWorker},
       {"*/5 * * * *", Cgc2046.Workers.LearningProgressWorker},
       {"*/5 * * * *", Cgc2046.Workers.ResearchProgressWorker},
       {"17 * * * *", Cgc2046.Workers.ApprovalReminderWorker},
       {"*/10 * * * *", Cgc2046.Workers.ReconciliationScanWorker},
       # 缴费闭环 U8（R8/F2）：订单 2h 限时窗，分钟级扫描把超时未付订单
       # + 报名 + 名额一体释放（迟 1 分钟的占位泄漏可接受，KTD5）。
       {"*/1 * * * *", Cgc2046.Workers.PaymentExpiryWorker},
       # 缴费闭环 U13 对账规⑦（R23/KTD11）：T+1 账单（昨日）夜间核对，
       # 03:23 避整点渠道尖峰；拉取失败告警不阻塞。
       {"23 3 * * *", Cgc2046.Workers.PaymentReconciliationWorker}
     ]}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
