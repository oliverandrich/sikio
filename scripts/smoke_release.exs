# SPDX-License-Identifier: AGPL-3.0-or-later

# Run with `mise run smoke`, which builds and checks a release for each database.
# SIKIO_DATABASE names the release to check. A SQLite release gets a file in a temporary
# directory. A Postgres one uses PG* credentials with CREATEDB and creates and drops its own
# random database.
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
    Support.temporary(fn directory ->
      pictures = Path.join(directory, "pictures")
      File.mkdir!(pictures)
      env = source |> Smoke.database_env(directory) |> Map.put("PICTURE_CACHE_DIR", pictures)
      Smoke.with_database(source, env, fn -> check(release, env) end)
    end)

    # An operator who migrates by hand: the opt-out, bin/migrate first, then the server.
    Support.temporary(fn directory ->
      pictures = Path.join(directory, "pictures")
      File.mkdir!(pictures)
      source = source <> "_by_hand"

      env =
        source
        |> Smoke.database_env(directory)
        |> Map.merge(%{"PICTURE_CACHE_DIR" => pictures, "SIKIO_MIGRATE_ON_START" => "false"})

      Smoke.with_database(source, env, fn -> check_by_hand(release, env) end)
    end)

    IO.puts(
      "#{Smoke.database()}: migration on start, repeat migration and migration by hand passed."
    )
  end

  # The server starts on an empty database and migrates it itself; bin/migrate afterwards finds
  # nothing left to do, which is what makes running it by hand safe.
  defp check(release, env) do
    env = Map.put(env, "PORT", Smoke.free_port())

    Smoke.with_server(Path.join(release, "server"), env, fn ->
      assert Smoke.await_landing("127.0.0.1", env["PORT"], "release HTTP startup") =~ "Sikio"
      check_https(env)
    end)

    # The newest table the library asks for, which is what makes this a check on the schema
    # rather than on one migration that happened to run. A release whose migrations lag the
    # library starts and then fails at the first thing that reads what is missing.
    assert Smoke.table?("ithibati_setup_codes", env)

    Smoke.run([Path.join(release, "migrate")], env)
  end

  defp check_by_hand(release, env) do
    Smoke.run([Path.join(release, "migrate")], env)
    assert Smoke.table?("ithibati_setup_codes", env)
    env = Map.put(env, "PORT", Smoke.free_port())

    Smoke.with_server(Path.join(release, "server"), env, fn ->
      assert Smoke.await_landing("127.0.0.1", env["PORT"], "release after bin/migrate") =~ "Sikio"
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
