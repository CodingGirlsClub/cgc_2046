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
      {AshAuthentication.Supervisor, otp_app: :cgc_2046},
      {DNSCluster, query: Application.get_env(:cgc_2046, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Cgc2046.PubSub},
      # Start a worker by calling: Cgc2046.Worker.start_link(arg)
      # {Cgc2046.Worker, arg},
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
