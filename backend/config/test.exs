import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :cgc_2046, Cgc2046.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "cgc_2046_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  # 下限 8：并发竞态测试（miniprogram_race_test）用 unboxed_run 各占一条真实连接，
  # 低核 CI runner（schedulers_online=2 → pool=4）会连接池耗尽超时
  pool_size: max(System.schedulers_online() * 2, 8)

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :cgc_2046, Cgc2046Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "u6jzM5sRxjBNWo4m+MqAwg6/MdILJllzbEfDPd/6RTOdjFwpRVixHQ49Y/VXfA5R",
  server: false

# In test we don't send emails
config :cgc_2046, Cgc2046.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# bcrypt cost 调低至 1：测试中数百次用户 fixture 经 AshAuthentication 真实哈希，
# 默认 cost 12 每次约 200ms（本机实测 212.5ms vs 0.9ms，235×），是串行段最大单一耗时。
config :bcrypt_elixir, :log_rounds, 1

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Ash 数据变更未触发对应通知时默认打 warning——测试大量走裸变更路径，
# 属预期噪音（Ash 官方提供的静默开关），刷屏掩盖真实失败信息
config :ash, :missed_notifications, :ignore

# Disable rate limiting in test (ETS table is shared across async tests)
config :cgc_2046, Cgc2046Web.Plugs.RateLimit, max_attempts: 999_999

# MCP 失败认证节流同款关闭（共享 ETS 表，async 401 测试会互相累计计数）
config :cgc_2046, Cgc2046Web.Plugs.McpAuthPlug, max_attempts: 999_999

# Oban 测试模式：manual——job 只入队不自动执行（Oban 内部自动禁用 queues/plugins，
# cron 不会在测试中触发）；断言用 Oban.Testing.assert_enqueued，执行用 perform_job。
config :cgc_2046, Oban, testing: :manual

# 小程序平台 HTTP 客户端走 Req.Test stub（测试进程按名注册；未 stub 的请求直接失败，
# 保证测试绝不发真实外网请求）。Req.Test ownership 沿 $callers 解析，Task 并发可用。
config :cgc_2046, :miniprogram_req_plug, {Req.Test, Cgc2046.MiniprogramClientStub}

# 微信 SDK client 不注册全局 Refresher/TokenChecker（跨用例泄漏）；
# wechat 分支 token 由测试直接种 WeChat.Storage.Cache，SDK 请求走 Tesla.Mock。
config :cgc_2046, :wechat_client_autostart, false

# 微信 SDK 请求层走 Tesla.Mock（Wechat.Requester 的 adapter 编译期注入；
# SDK 自带 test 分支在宿主构建不生效——见 wechat_client.ex 模块注释）。
config :cgc_2046, :wechat_tesla_adapter, Tesla.Mock

# 缴费闭环 U4（KTD3）：测试全量注入 FakeProvider——渠道密钥零依赖，
# 绝不发真实外网请求（微信沙箱不可靠 #172，以 mock 为主）。
config :cgc_2046, :payments_providers, %{
  wechat: Cgc2046.Payments.Providers.Fake,
  alipay: Cgc2046.Payments.Providers.Fake
}

# SendCloud SMS（plan 002 U3）：测试经 Req.Test stub 拦截（未 stub 的请求直接
# 失败，绝不发真实短信）；凭证为 test 值（configured? 生效走真实 deliver 分支）。
config :cgc_2046, :sms_sendcloud,
  sms_user: "test-sms-user",
  sms_key: "test-sms-key",
  template_id: "test-sms-template"

config :cgc_2046, :sms_req_plug, {Req.Test, Cgc2046.SmsSendCloudStub}

# 微信网站应用扫码登录（plan 002 U4）：测试经 Req.Test stub 拦截
config :cgc_2046, :wechat_web_req_plug, {Req.Test, Cgc2046.WechatWebStub}

# 凭证为 test 值（config.exs 已改 nil，test 显式覆盖使 configured? 生效）
config :cgc_2046,
  wechat_web: [
    appid: "test-wechat-web-appid",
    secret: "test-wechat-web-secret"
  ]
