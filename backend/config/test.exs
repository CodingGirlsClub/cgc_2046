import Config

# worktree 并行隔离：附属 git worktree 的 mix test 各用各的库（规则见 worktree_suffix.exs），
# 互不干扰；主 checkout 与 CI 为 cgc_2046_test + MIX_TEST_PARTITION。
{branch_suffix, _} = Code.eval_file("worktree_suffix.exs", __DIR__)

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.

# 并发用例上限——连接池需求由它推导，改 pool_size 前先读这段。
# ExUnit 分两段跑：async 段最多 max_cases 个用例同时跑，各经 Sandbox.start_owner!
# 独占 1 条连接；sync 段串行，但单用例还会额外要连接（unboxed_run 并发 Task 峰值
# 4 个，迁移测试另起 pool_size 2 的克隆库 Repo）。ExUnit 默认 max_cases =
# schedulers_online * 2（16 核 → 32），旧配置把 pool_size 取成同一个数 → async 段
# 零余量：32 个用例占满连接后，同池的 Oban 通知器/用例内额外进程只能排队，饱和
# 几秒后 DBConnection 丢请求——实测 3 轮全量 2 轮随机红（"connection not available
# and request was dropped from queue after 4000ms"，红在 Sandbox.checkout）。
# 故 pool_size = max_cases + 4 是硬要求。
# 上限 8 是整机约束：本机 Postgres max_connections=100，多 worktree 并行时总连接
# ≈ pool_size × worktree 数（实测峰值 15/worktree：迁移测试会另起克隆库 Repo），
# 旧的 32 条/worktree 三套并行就打爆整机（实测 "FATAL 53300 too many clients
# already"，连 Oban 通知器都连不上）。12 条/worktree → 5 套并行 75 条，加 dev
# server/psql ~12 条仍留在 100 内；要 7 套并行得把 max_connections 提上去（不在仓内）。
# 压上限不付代价：全量 ~75s 里 async 段只占 10-14s，其余 ~63s 是串行 sync 段
# （与 cap 无关，是墙钟主项）；cap 32/12/8 三档的 async 段实测落在同一区间。
# CI 同样按 max_cases + 4 取值：2 核 runner 4/8（与原配置一致），4 核 runner 8/12
# （旧配置 8/8 零余量，同一个坑）。单次调高并发（`mix test --max-cases N`）必须
# 连这里的上限一起改——CLI 参数不会让 pool_size 跟着长。
test_max_cases = min(System.schedulers_online() * 2, 8)

config :ex_unit, max_cases: test_max_cases

config :cgc_2046, Cgc2046.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "cgc_2046_test#{System.get_env("MIX_TEST_PARTITION")}" <> branch_suffix,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: test_max_cases + 4

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

# Test 永远不读取开发机的私有 playbook 目录；用例需要增量时显式覆盖并在退出时恢复。
config :cgc_2046,
       :playbooks_dir,
       Path.expand("../test/support/playbooks-missing", __DIR__)

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

# 闪念间唤醒短信（U8）：测试给 stub 模板 ID 使 configured? 走真实 deliver 分支
# （请求仍被上面的 Req.Test 拦截，绝不外呼）。
config :cgc_2046, :flashback_sms, template_id: "test-flashback-sms-template"

# 微信网站应用扫码登录（plan 002 U4）：测试经 Req.Test stub 拦截
config :cgc_2046, :wechat_web_req_plug, {Req.Test, Cgc2046.WechatWebStub}

# 凭证为 test 值（config.exs 已改 nil，test 显式覆盖使 configured? 生效）
config :cgc_2046,
  wechat_web: [
    appid: "test-wechat-web-appid",
    secret: "test-wechat-web-secret"
  ]
