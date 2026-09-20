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

# Background work runs on the application's own database. The maintenance queue is separate from
# the feed queue so a slow refresh cannot delay expiring a session.
config :sikio, Oban,
  repo: Sikio.Repo,
  queues: [feeds: 3, maintenance: 1],
  cron: [
    crontab: [
      {"*/15 * * * *", Sikio.Feeds.Scheduler},
      {"*/15 * * * *", Sikio.Accounts.Cleanup}
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

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# AGPL section 13 (network use): whoever runs this for other people has to offer them its
# source. The footer links here, and a deployment that modified Sikio overrides SOURCE_URL
# (runtime.exs) to point at its own repository.
config :sikio, :source_url, "https://github.com/oliverandrich/sikio"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
