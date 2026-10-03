# SPDX-License-Identifier: AGPL-3.0-or-later

# SQLite has one writer, and each test holds a write transaction for as long as it runs, so its
# tests take turns. The suite's time is in the browser tests, which take turns on either database.
if Application.fetch_env!(:sikio, :database) == :sqlite,
  do: ExUnit.start(max_cases: 1),
  else: ExUnit.start()

Ecto.Adapters.SQL.Sandbox.mode(Sikio.Repo, :manual)

Application.put_env(:wallaby, :chromedriver, path: SikioWeb.BrowserDriver.path(), headless: true)
Application.put_env(:wallaby, :base_url, SikioWeb.Endpoint.url())
{:ok, _} = Application.ensure_all_started(:wallaby)
