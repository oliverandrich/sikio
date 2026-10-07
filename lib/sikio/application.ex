# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # These checks run before any child starts, so before the endpoint binds a port.
    # With an open initial claim, the first visitor could claim the instance.
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
      # Migrates when `:migrate_on_start` is true, the release default; see config/runtime.exs.
      # It runs before Oban, whose tables a migration may create, and before the endpoint.
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

  @doc """
  Returns the Oban options. The engine is `Oban.Engines.Basic` on PostgreSQL and
  `Oban.Engines.Lite` on SQLite.
  """
  def oban do
    engine = if Sikio.Repo.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    Keyword.put(Application.fetch_env!(:sikio, Oban), :engine, engine)
  end

  # Passes configuration changes from a release upgrade to the endpoint.
  @impl true
  def config_change(changed, _new, removed) do
    SikioWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
