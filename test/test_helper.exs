ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Sikio.Repo, :manual)

Application.put_env(:wallaby, :chromedriver, path: SikioWeb.BrowserDriver.path(), headless: true)
Application.put_env(:wallaby, :base_url, SikioWeb.Endpoint.url())
{:ok, _} = Application.ensure_all_started(:wallaby)
