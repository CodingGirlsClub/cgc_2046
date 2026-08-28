defmodule Cgc2046.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Cgc2046Web.Telemetry,
      Cgc2046.Repo,
      {DNSCluster, query: Application.get_env(:cgc_2046, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Cgc2046.PubSub},
      # Start a worker by calling: Cgc2046.Worker.start_link(arg)
      # {Cgc2046.Worker, arg},
      # ETS 限流器（signIn/signUp 5 次/15 分钟，零依赖）
      Cgc2046Web.Plugs.RateLimit,
      # Workflow 信号总线（Slice C #35，JidoAdapter.publish/subscribe 前置；
      # 阶段 2 用内存总线，Postgres journal 适配器阶段 4）
      {Jido.Signal.Bus, name: Cgc2046.Workflows.JidoAdapter.bus_name()},
      # Step handler 注册表（Slice C #35，ADR-0003 两阶段初始化；长命进程持有 ETS 表，
      # 注册不随短命调用进程丢失——SC2-011）
      Cgc2046.Workflows.StepHandlerRegistry,
      # 教研 workflow 实例化（#39 阶段 6：订阅 event/course.launched 信号 → 创建教研 run）
      Cgc2046.Curriculum.Instantiator,
      # 生命周期级联（E-9 #124：订阅 event/course.ended 信号 → 停教研 run 回收）
      Cgc2046.Curriculum.Reaper,
      # 赞助关系级联（E-3 #48：订阅 event.ended → Event 级 active Sponsorship 转 ended）
      Cgc2046.Events.SponsorshipEndedSubscriber,
      # Event cancelled 批量退款（缴费闭环 U9：订阅 event.ended，回查 cancelled
      # 才批量退——paid 逐笔退款 / payment_pending 取消释放）。
      Cgc2046.Workers.OfferingCancelRefundWorker,
      # 学习 workflow 实例化（E-7 #122：订阅 enrollment.completed → 幂等种 learning run）
      Cgc2046.Workflows.LearningInstantiator,
      # Enrollment 审批结果信号 → Oban 异步订阅消息（不阻塞 action 事务）。
      Cgc2046.NotificationSubscriber,
      # SpeakerInvitation 生命周期信号 → Oban 异步订阅消息（E-4 #49；
      # SignalIdempotency 幂等去重）。
      Cgc2046.SpeakerSubscriber,
      # 分享链接预生成（plan 011：订阅 event/course.launched → Oban 异步生成 scheme）。
      Cgc2046.Workflows.ShareSchemeInstantiator,
      # AshAuthentication supervisor (periodic token cleanup etc.)
      {AshAuthentication.Supervisor, otp_app: :cgc_2046},
      # MCP server（Slice D #42，anubis_mcp streamable HTTP；挂载见 router :mcp pipeline）。
      # start: true 强制启动 session 设施（registry/监督树，无独立 HTTP listener）——
      # anubis 默认按 :phoenix, :serve_endpoints 探测，test 环境为 false 会导致
      # persistent_term 缺失、Plug 无法工作；本 server 永远经 Phoenix forward 提供。
      {Cgc2046.Mcp.Server, transport: {:streamable_http, start: true}},
      # WechatPay 动态 client 宿主（plan 007 B1：SDK client = Refresher.Pay 平台
      # 证书加载/12h 轮换 + per-client 命名 Finch 池；首次真实调用按配置指纹挂载，
      # 未配置时恒空）。
      {DynamicSupervisor, name: Cgc2046.Payments.ClientSup},
      # 0C：Oban（审批超时扫描 + 48h 提醒 cron；需在 Repo 之后启动）
      {Oban, Application.fetch_env!(:cgc_2046, Oban)},
      # Start to serve requests, typically the last entry
      Cgc2046Web.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Cgc2046.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Cgc2046Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
