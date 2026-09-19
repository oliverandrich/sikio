# Two local disposable repositories stand in for local/offsite destinations.
# Requires a built release, restic and PG* credentials with CREATEDB.
Code.require_file("operations/smoke.exs", __DIR__)
Code.require_file("operations/backup_runner.exs", __DIR__)

defmodule Sikio.Operations.BackupSmoke do
  import ExUnit.Assertions
  alias Sikio.Operations.{BackupRunner, Smoke, Support}

  def main do
    database = "sikio_backup_smoke_" <> Support.token(8)
    env = Smoke.database_env(database)

    Support.temporary(fn directory ->
      password = Path.join(directory, "password")
      Support.private_write(password, Support.token(32))

      env =
        Map.merge(env, %{
          "RESTIC_REPOSITORY" => Path.join(directory, "local"),
          "RESTIC_PASSWORD_FILE" => password,
          "SIKIO_REMOTE_REPOSITORY" => Path.join(directory, "second"),
          "SIKIO_BACKUP_ID" => "smoke-test",
          "SIKIO_BACKUP_STATE_DIR" => Path.join(directory, "state")
        })

      Smoke.with_database(database, env, fn -> check(env, directory) end)
    end)

    IO.puts(
      "Encrypted backup, second-repository copy, retention, two data-checked restores, status and wrong-password rejection passed."
    )
  end

  defp check(env, directory) do
    Smoke.run([Path.join(Smoke.release(), "migrate")], env)

    Smoke.query(
      "INSERT INTO users (username, inserted_at, updated_at) VALUES ('encrypted_restore_probe', now(), now())",
      env
    )

    Smoke.run(["restic", "init"], env)
    Smoke.run(["restic", "init"], BackupRunner.remote_env(env))
    # Exercise the packaged CLI using its bundled runtime, without Phoenix config.
    cli = Path.join([Smoke.release(), "..", "ops", "backup_runner"])
    cli_env = Map.merge(env, %{"DATABASE_URL" => nil, "SECRET_KEY_BASE" => nil})
    assert JSON.decode!(Smoke.run([cli, "backup"], cli_env))["offsite"]

    checked = fn args, connection, options ->
      if hd(args) == "dropdb" do
        # Always clean up even if the content assertion fails.
        try do
          assert Smoke.query("SELECT username FROM users", connection) ==
                   "encrypted_restore_probe"

          send(self(), :restored)
        after
          Support.run(args, connection, options)
        end
      else
        Support.run(args, connection, options)
      end
    end

    assert BackupRunner.execute("verify", env, checked)["offsite"]
    assert_received :restored
    assert_received :restored
    assert JSON.decode!(Smoke.run([cli, "status"], cli_env))["verify"]["offsite"]
    wrong = Path.join(directory, "wrong-password")
    Support.private_write(wrong, Support.token(32))

    assert_raise Support.CommandError, fn ->
      Smoke.run(["restic", "snapshots"], Map.put(env, "RESTIC_PASSWORD_FILE", wrong))
    end
  end
end

Sikio.Operations.BackupSmoke.main()
