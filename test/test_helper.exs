# SPDX-License-Identifier: AGPL-3.0-or-later

# SQLite allows one writer, and each test holds a write transaction while it runs.
# So SQLite tests run with `max_cases: 1`.
# Most suite time is in the browser features, which run sequentially on either database.
# The features test the interface, which behaves alike on both databases, so they run on SQLite.
# Queries, locks and migrations differ between the databases and are tested on both.
# `mix test --include feature` also runs the features on PostgreSQL.
# Logs are captured and shown only for failing tests.
if Application.fetch_env!(:sikio, :database) == :sqlite,
  do: ExUnit.start(max_cases: 1, capture_log: true),
  else: ExUnit.start(exclude: [:feature], capture_log: true)

Ecto.Adapters.SQL.Sandbox.mode(Sikio.Repo, :manual)

Application.put_env(:wallaby, :chromedriver, path: SikioWeb.BrowserDriver.path(), headless: true)

# Removes the image cache, so no test reads images fetched in an earlier run.
File.rm_rf!(Sikio.Pictures.cache_dir())

Application.put_env(:wallaby, :base_url, SikioWeb.Endpoint.url())
{:ok, _} = Application.ensure_all_started(:wallaby)
{:ok, _} = SikioWeb.BrowserPool.start_link()
ExUnit.after_suite(fn _ -> SikioWeb.BrowserPool.stop() end)
