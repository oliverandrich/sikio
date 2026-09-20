# SPDX-License-Identifier: AGPL-3.0-or-later

import Config

config :wallaby,
  otp_app: :sikio,
  driver: Wallaby.Chrome,
  js_logger: nil,
  screenshot_on_failure: true

config :sikio, sql_sandbox: true

# Jobs are inserted and performed by the tests that are about them, never in the background of one
# that is about something else.
config :sikio, Oban, testing: :manual

# No feed test uses real DNS or the network. Every request is answered by the stub its own test
# installed, and a test that forgets to install one fails rather than reaching a stranger's server.
config :sikio,
  feed_resolver: &Sikio.FeedFixtures.resolve/1,
  feed_http_plug: {Req.Test, Sikio.Feeds.HTTP}

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :sikio, Sikio.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: "sikio_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :sikio, SikioWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "bzKS9Jh1ns5yilHq+s+kM1Jn6i985JEDr8HyOJ/bKi0s7+31fZEsBP9rYY/PfYRe",
  server: true

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
