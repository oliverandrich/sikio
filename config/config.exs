# SPDX-License-Identifier: AGPL-3.0-or-later

# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ithibati,
  repo: Sikio.Repo,
  user_schema: Sikio.Accounts.User,
  invitation_schema: Sikio.Accounts.Invitation,
  users_key_type: :id

config :phoenix, filter_parameters: ["password", "secret", "token", "code", "credential"]

# So an uploaded subscription list can be accepted by its own extension rather than only as XML.
config :mime, :types, %{"text/x-opml" => ["opml"]}

# A build serves one database, chosen in mix.exs from SIKIO_DATABASE when it is compiled. The
# repository's adapter and the job queue's engine follow it.
database =
  case System.fetch_env!("SIKIO_DATABASE") do
    "sqlite" -> :sqlite
    "postgres" -> :postgres
    other -> raise "SIKIO_DATABASE must be sqlite or postgres, not #{inspect(other)}"
  end

config :sikio, :database, database

# SQLite as dj-lite sets it up for Django: a write-ahead log so readers never wait for the writer,
# a writer that waits up to five seconds rather than failing, and transactions that take the write
# lock when they begin, so two never deadlock upgrading a read. Every environment uses them.
if database == :sqlite do
  config :sikio, Sikio.Repo,
    journal_mode: :wal,
    synchronous: :normal,
    temp_store: :memory,
    journal_size_limit: 27_103_364,
    cache_size: 2000,
    busy_timeout: 5000,
    foreign_keys: :on,
    default_transaction_mode: :immediate,
    custom_pragmas: [mmap_size: 134_217_728]
end

# Background work runs on the application's own database. The maintenance queue is separate from
# the feed queue so a slow refresh cannot delay expiring a session.
config :sikio, Oban,
  repo: Sikio.Repo,
  engine: if(database == :sqlite, do: Oban.Engines.Lite, else: Oban.Engines.Basic),
  queues: [feeds: 3, maintenance: 1],
  cron: [
    crontab: [
      {"*/15 * * * *", Sikio.Feeds.Scheduler},
      {"*/15 * * * *", Sikio.Accounts.Cleanup},
      {"17 3 * * *", Sikio.Pictures.Cleanup}
    ]
  ],
  pruner: [max_age: 86_400]

config :sikio, SikioWeb.Gettext, default_locale: "en"

config :sikio,
  ecto_repos: [Sikio.Repo],
  generators: [timestamp_type: :utc_datetime],
  locales: ["en", "de"]

# Configure the endpoint
config :sikio, SikioWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SikioWeb.ErrorHTML, json: SikioWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Sikio.PubSub,
  live_view: [signing_salt: "SUKy3ljK"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  sikio: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  sikio: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Swoosh talks to an SMTP server directly, so it needs no HTTP client of its own.
config :swoosh, :api_client, false

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# AGPL section 13 (network use): whoever runs this for other people has to offer them its
# source. The footer links here, and a deployment that modified Sikio overrides SOURCE_URL
# (runtime.exs) to point at its own repository.
config :sikio, :source_url, "https://github.com/oliverandrich/sikio"

# A public instance is reachable before anybody has claimed it, so the first account asks for a
# code the operator issues on the host. Set for every environment rather than for production
# alone: a posture that only holds in production is a posture nothing runs against.
# `Sikio.Claim` refuses any other value where an instance starts.
config :ithibati, initial_claim: :operator_code

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
