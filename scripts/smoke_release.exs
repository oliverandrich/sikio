# Run with `mise exec -- elixir scripts/smoke_release.exs` after building the release.
# Uses PG* credentials with CREATEDB; only creates/drops its own random databases.
Code.require_file("operations/smoke.exs", __DIR__)

defmodule Sikio.Operations.ReleaseSmoke do
  import ExUnit.Assertions
  import Bitwise
  alias Sikio.Operations.{Smoke, Support}

  def main do
    release = Smoke.release()

    for name <-
          ~w(backup restore backup_runner backup_runner.exs operations/backup_runner.exs operations/support.exs) do
      assert File.regular?(Path.join([release, "..", "ops", name])), "Release is missing #{name}"
    end

    source = "sikio_smoke_" <> Support.token(6)
    target = "sikio_smoke_" <> Support.token(6)
    env = Smoke.database_env(source)

    Support.temporary(fn directory ->
      Smoke.with_databases([source, target], env, fn ->
        check(release, target, directory, env)
      end)
    end)

    IO.puts(
      "Release migration, repeat migration, private backup, real restore, overwrite refusal and HTTP startup passed."
    )
  end

  defp check(release, target, directory, env) do
    Smoke.run([Path.join(release, "migrate")], env)
    assert Smoke.query("SELECT to_regclass('public.ithibati_challenges') IS NOT NULL", env) == "t"
    Smoke.run([Path.join(release, "migrate")], env)

    Smoke.query(
      "INSERT INTO users (username, inserted_at, updated_at) VALUES ('restore_probe', now(), now())",
      env
    )

    count = Smoke.query("SELECT count(*) FROM schema_migrations", env)
    archive = Path.join(directory, "backup.dump")
    Smoke.run([Smoke.script("backup"), archive], env)
    assert band(File.stat!(archive).mode, 0o777) == 0o600
    restored = Map.put(env, "PGDATABASE", target)
    Smoke.run([Smoke.script("restore"), archive], restored)
    assert Smoke.query("SELECT username FROM users", restored) == "restore_probe"
    assert Smoke.query("SELECT count(*) FROM schema_migrations", restored) == count

    assert_raise Support.CommandError, fn ->
      Smoke.run([Smoke.script("restore"), archive], restored)
    end

    env = Map.put(env, "PORT", Smoke.free_port())

    Smoke.with_server(Path.join(release, "server"), env, fn ->
      assert Smoke.await_landing("127.0.0.1", env["PORT"], "release HTTP startup") =~ "Sikio"
    end)
  end
end

Sikio.Operations.ReleaseSmoke.main()
