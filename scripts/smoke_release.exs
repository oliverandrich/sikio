# SPDX-License-Identifier: AGPL-3.0-or-later

# Run with `mise exec -- elixir scripts/smoke_release.exs` after building the release.
# Uses PG* credentials with CREATEDB; only creates/drops its own random database.
Code.require_file("support/smoke.exs", __DIR__)

defmodule Sikio.ReleaseSmoke do
  import ExUnit.Assertions
  alias Sikio.ReleaseSmoke.{Smoke, Support}

  def main do
    release = Smoke.release()

    refute File.exists?(Path.join([release, "..", "ops"])),
           "Release must contain only the application, not backup/restore operations"

    source = "sikio_smoke_" <> Support.token(6)

    # The release refuses to start without a place for pictures outside itself.
    Support.temporary(fn pictures ->
      env = source |> Smoke.database_env() |> Map.put("PICTURE_CACHE_DIR", pictures)
      Smoke.with_database(source, env, fn -> check(release, env) end)
    end)

    IO.puts("Release migration, repeat migration and HTTP startup passed.")
  end

  defp check(release, env) do
    Smoke.run([Path.join(release, "migrate")], env)

    # The newest table the library asks for, which is what makes this a check on the schema
    # rather than on one migration that happened to run. A release whose migrations lag the
    # library starts and then fails at the first thing that reads what is missing.
    assert Smoke.query("SELECT to_regclass('public.ithibati_setup_codes') IS NOT NULL", env) == "t"

    Smoke.run([Path.join(release, "migrate")], env)

    env = Map.put(env, "PORT", Smoke.free_port())

    Smoke.with_server(Path.join(release, "server"), env, fn ->
      assert Smoke.await_landing("127.0.0.1", env["PORT"], "release HTTP startup") =~ "Sikio"
      check_https(env)
    end)
  end

  # `force_ssl` is compiled into the release and excludes localhost, which every other probe here
  # uses. So these ask for another name. Plain http has to be sent to https on the configured
  # host, never the one asked for, and a request Caddy marks as https has to be served: a wrong
  # rewrite key loops behind the proxy instead.
  defp check_https(env) do
    host = {"host", "sikio.example"}
    port = env["PORT"]

    assert {301, headers, _} = Smoke.request("127.0.0.1", port, "/health", [host])
    assert headers["location"] == "https://#{env["PHX_HOST"]}/health"

    assert {200, headers, _} =
             Smoke.request("127.0.0.1", port, "/health", [host, {"x-forwarded-proto", "https"}])

    assert headers["strict-transport-security"] =~ "max-age="
  end
end

Sikio.ReleaseSmoke.main()
