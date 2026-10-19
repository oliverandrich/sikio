# SPDX-License-Identifier: AGPL-3.0-or-later

# SQLite allows one writer, and each test holds a write transaction while it runs.
# So SQLite tests run with `max_cases: 1`.
# Most suite time is in the browser features, which run sequentially on either database.
# The features test the interface, which behaves alike on both databases, so they run on SQLite.
# Queries, locks and migrations differ between the databases and are tested on both.
# `mix test --include feature` also runs the features on PostgreSQL.
# Tests tagged `:postgres` need both databases and run in the PostgreSQL pass alone.
# Logs are captured and shown only for failing tests.
if Application.fetch_env!(:sikio, :database) == :sqlite,
  do: ExUnit.start(max_cases: 1, capture_log: true, exclude: [:postgres]),
  else: ExUnit.start(exclude: [:feature], capture_log: true)

Ecto.Adapters.SQL.Sandbox.mode(Sikio.Repo, :manual)

# Removes the image cache, so no test reads images fetched in an earlier run.
File.rm_rf!(Sikio.Pictures.cache_dir())

# The PostgreSQL pass excludes the browser features, so it needs neither node nor Playwright.
ex_unit = ExUnit.configuration()

if :feature in ex_unit[:include] or :feature not in ex_unit[:exclude] do
  Application.put_env(:phoenix_test, :base_url, SikioWeb.Endpoint.url())
  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
end
