defmodule Sikio.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Sikio.AuthRateLimiter,
      SikioWeb.Telemetry,
      Sikio.Repo,
      {DNSCluster, query: Application.get_env(:sikio, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Sikio.PubSub},
      # Start a worker by calling: Sikio.Worker.start_link(arg)
      # {Sikio.Worker, arg},
      # Start to serve requests, typically the last entry
      SikioWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Sikio.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SikioWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
