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
      # AshAuthentication supervisor (periodic token cleanup etc.)
      {AshAuthentication.Supervisor, otp_app: :cgc_2046},
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
