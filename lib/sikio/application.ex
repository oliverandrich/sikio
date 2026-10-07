# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Before anything binds a port. An instance whose claim is not protected must not serve one
    # request, because the first stranger to arrive would be the one who claims it.
    Sikio.Claim.verify!()
    Sikio.Identity.verify!(Sikio.Mailer.configured?())
    Sikio.Logging.attach_job_failures()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Sikio.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  @doc false
  def children do
    [
      Sikio.AuthRateLimiter,
      SikioWeb.Telemetry,
      Sikio.Repo,
      # A release migrates here, before the queue whose tables it may create and before the
      # endpoint serves anything; see config/runtime.exs. Elsewhere it is skipped.
      {Ecto.Migrator,
       repos: Application.fetch_env!(:sikio, :ecto_repos),
       skip: !Application.get_env(:sikio, :migrate_on_start, false)},
      {DNSCluster, query: Application.get_env(:sikio, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Sikio.PubSub},
      {Oban, oban()},
      # Start to serve requests, typically the last entry
      SikioWeb.Endpoint
    ]
  end

  @doc "The options the job queue starts with. Its engine follows the database the application uses."
  def oban do
    engine = if Sikio.Repo.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    Keyword.put(Application.fetch_env!(:sikio, Oban), :engine, engine)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SikioWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
