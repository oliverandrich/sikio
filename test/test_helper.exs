# SPDX-License-Identifier: AGPL-3.0-or-later

# SQLite has one writer, and each test holds a write transaction for as long as it runs, so its
# tests take turns. The suite's time is in the browser tests, which take turns on either database.
# The browser features test the interface, which behaves alike on both databases, so they run on
# SQLite alone. What differs between the two, the queries, locks and migrations, is tested on
# both. `mix test --include feature` runs them on PostgreSQL as well.
if Application.fetch_env!(:sikio, :database) == :sqlite,
  do: ExUnit.start(max_cases: 1),
  else: ExUnit.start(exclude: [:feature])

Ecto.Adapters.SQL.Sandbox.mode(Sikio.Repo, :manual)

Application.put_env(:wallaby, :chromedriver, path: SikioWeb.BrowserDriver.path(), headless: true)

# Pictures fetched in an earlier run would answer from the cache, so each run starts without one.
File.rm_rf!(Sikio.Pictures.cache_dir())

Application.put_env(:wallaby, :base_url, SikioWeb.Endpoint.url())
{:ok, _} = Application.ensure_all_started(:wallaby)
{:ok, _} = SikioWeb.BrowserPool.start_link()
ExUnit.after_suite(fn _ -> SikioWeb.BrowserPool.stop() end)
