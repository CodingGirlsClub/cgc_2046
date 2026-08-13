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
  pool_size: max(System.schedulers_online() * 2, 8),
  # 异步信号订阅方（NotificationSubscriber 等应用级进程）在共享 sandbox 连接上
  # 与测试进程并发查询；提高 checkout 排队预算，避免共享连接短暂繁忙时订阅方
  # 的投递被 DBConnection 丢弃（async_signal_test 异步最终一致的确定性）。
  queue_target: 2_000,
  queue_interval: 2_000

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

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Disable rate limiting in test (ETS table is shared across async tests)
config :cgc_2046, Cgc2046Web.Plugs.RateLimit, max_attempts: 999_999

# Oban 测试模式：manual——job 只入队不自动执行（Oban 内部自动禁用 queues/plugins，
# cron 不会在测试中触发）；断言用 Oban.Testing.assert_enqueued，执行用 perform_job。
config :cgc_2046, Oban, testing: :manual

# 小程序平台 HTTP 客户端走 Req.Test stub（测试进程按名注册；未 stub 的请求直接失败，
# 保证测试绝不发真实外网请求）。Req.Test ownership 沿 $callers 解析，Task 并发可用。
config :cgc_2046, :miniprogram_req_plug, {Req.Test, Cgc2046.MiniprogramClientStub}
