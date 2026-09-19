# Checks Apple Container runtime behavior, not Docker Compose orchestration.
# Build sikio:container-smoke and sikio-backup:container-smoke first.
Code.require_file("operations/smoke.exs", __DIR__)

defmodule Sikio.Operations.ContainerSmoke do
  import ExUnit.Assertions
  alias Sikio.Operations.{Smoke, Support}

  def main do
    prefix = "sikio-smoke-" <> Support.token(5)
    Process.put(:cleanup, [])

    Support.temporary(fn directory ->
      try do
        check(prefix, directory)
      after
        Enum.each(Process.get(:cleanup), &cleanup_resource/1)
      end
    end)
  end

  # Best effort per resource so one cleanup error cannot skip the rest.
  defp cleanup_resource(args) do
    case System.cmd("container", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, _} -> IO.puts(:stderr, "Container cleanup failed: #{Enum.join(args, " ")}")
    end
  end

  defp cli(args), do: Smoke.run(["container" | args], %{})
  defp cleanup(args), do: Process.put(:cleanup, [args | Process.get(:cleanup)])

  defp start(name, image, options, command \\ []) do
    cleanup(["delete", name])
    cleanup(["stop", name])

    cli(
      ["run", "-d", "--name", name, "--network", Process.get(:network)] ++
        options ++ [image] ++ command
    )
  end

  defp sql(db, query, database \\ "sikio") do
    cli([
      "exec",
      db,
      "psql",
      "-U",
      "sikio",
      "-d",
      database,
      "-X",
      "-v",
      "ON_ERROR_STOP=1",
      "-Atc",
      query
    ])
  end

  defp address(name) do
    [info] = cli(["inspect", name]) |> JSON.decode!()
    info["status"]["networks"] |> hd() |> Map.fetch!("ipv4Address") |> String.split("/") |> hd()
  end

  defp check(prefix, directory) do
    Process.put(:network, prefix)
    db = prefix <> "-db"
    app = prefix <> "-app"
    worker = prefix <> "-backup"
    password = Support.token(24)

    for name <- ~w(backups secrets) do
      path = Path.join(directory, name)
      File.mkdir!(path)
      File.chmod!(path, 0o700)
    end

    Support.private_write(Path.join(directory, "secrets/password"), Support.token(32))
    cli(["network", "create", "--internal", prefix])
    cleanup(["network", "delete", prefix])
    cli(["volume", "create", prefix])
    cleanup(["volume", "delete", prefix])

    db_options = [
      "-e",
      "POSTGRES_USER=sikio",
      "-e",
      "POSTGRES_DB=sikio",
      "-e",
      "POSTGRES_PASSWORD=#{password}",
      "-v",
      "#{prefix}:/var/lib/postgresql",
      "-v",
      "#{Smoke.root()}/scripts:/ops:ro"
    ]

    start(db, "postgres:18.6", db_options)
    Smoke.eventually(fn -> sql(db, "SELECT 1") end, "PostgreSQL readiness")
    db_ip = address(db)

    app_env = [
      "-e",
      "DATABASE_URL=ecto://sikio:#{password}@#{db_ip}/sikio",
      "-e",
      "SECRET_KEY_BASE=#{Support.token(64)}",
      "-e",
      "PHX_HOST=localhost",
      "-e",
      "PHX_BIND_IP=0.0.0.0",
      "-e",
      "PORT=4000",
      "-e",
      "POOL_SIZE=10"
    ]

    for _ <- 1..2 do
      cli(
        ["run", "--rm", "--network", prefix] ++
          app_env ++ ["sikio:container-smoke", "/app/bin/migrate"]
      )
    end

    assert sql(db, "SELECT to_regclass('public.ithibati_challenges') IS NOT NULL") == "t"

    sql(
      db,
      "INSERT INTO users (username, inserted_at, updated_at) VALUES ('container_restore_probe', now(), now())"
    )

    count = sql(db, "SELECT count(*) FROM schema_migrations")
    start(app, "sikio:container-smoke", ["--init" | app_env])
    assert cli(["exec", app, "id", "-u"]) != "0"
    ip = address(app)
    html = Smoke.await_landing(ip, 4000, "release HTTP startup")
    assert html =~ "Sikio"
    assets = Regex.scan(~r/(?:src|href)="(\/assets\/[^"?]+)/, html, capture: :all_but_first)
    refute assets == []
    for [asset] <- assets, do: refute(Smoke.http(ip, 4000, asset) == "")
    IO.puts("Migrations, non-root release startup, rendered page and compiled assets passed.")

    cli([
      "exec",
      "-e",
      "PGUSER=sikio",
      "-e",
      "PGDATABASE=sikio",
      db,
      "/ops/backup",
      "/tmp/sikio.dump"
    ])

    assert cli(["exec", db, "stat", "-c", "%a", "/tmp/sikio.dump"]) == "600"
    cli(["exec", db, "createdb", "-U", "sikio", "sikio_restored"])

    restore = [
      "exec",
      "-e",
      "PGUSER=sikio",
      "-e",
      "PGDATABASE=sikio_restored",
      db,
      "/ops/restore",
      "/tmp/sikio.dump"
    ]

    cli(restore)
    assert_content(db, "sikio_restored", count)
    assert_raise Support.CommandError, fn -> cli(restore) end
    check_worker(worker, db, db_ip, prefix, password, directory, count)
    cli(["stop", app])
    cli(["start", app])
    ip = address(app)
    assert Smoke.await_landing(ip, 4000, "release restart") =~ "Sikio"
    cli(["stop", app])
    cli(["stop", db])
    cli(["delete", db])
    # The original cleanup entries also cover the replacement with the same name.
    cli(["run", "-d", "--name", db, "--network", prefix] ++ db_options ++ ["postgres:18.6"])
    Smoke.eventually(fn -> sql(db, "SELECT 1") end, "PostgreSQL recreation")
    assert sql(db, "SELECT username FROM users") == "container_restore_probe"

    IO.puts(
      "Backup, encrypted repositories, restore probes, app restart and persistent volume passed."
    )
  end

  defp check_worker(worker, db, ip, prefix, password, directory, count) do
    env = [
      "-e",
      "PGHOST=#{ip}",
      "-e",
      "PGUSER=sikio",
      "-e",
      "PGDATABASE=sikio",
      "-e",
      "PGPASSWORD=#{password}",
      "-e",
      "RESTIC_REPOSITORY=/backups/local",
      "-e",
      "RESTIC_PASSWORD_FILE=/secrets/password",
      "-e",
      "SIKIO_REMOTE_REPOSITORY=/backups/second",
      "-e",
      "SIKIO_BACKUP_ID=#{prefix}",
      "-e",
      "SIKIO_BACKUP_STATE_DIR=/backups/state"
    ]

    start(
      worker,
      "sikio-backup:container-smoke",
      ["--init", "--entrypoint", "sleep", "--tmpfs", "/tmp:mode=1777"] ++
        env ++
        ["-v", "#{directory}/backups:/backups", "-v", "#{directory}/secrets:/secrets:ro"],
      ["infinity"]
    )

    cli(["exec", worker, "restic", "init"])
    cli(["exec", worker, "env", "RESTIC_REPOSITORY=/backups/second", "restic", "init"])

    for action <- ~w(backup verify status) do
      result = cli(["exec", worker, "/ops/backup_runner", action]) |> JSON.decode!()
      if action != "status", do: assert(result["offsite"])
    end

    for repository <- ~w(local second) do
      cli([
        "exec",
        worker,
        "env",
        "RESTIC_REPOSITORY=/backups/#{repository}",
        "sh",
        "-c",
        "umask 077; restic dump latest /sikio.dump > /tmp/encrypted.dump"
      ])

      target = "sikio_" <> repository
      cli(["exec", worker, "createdb", target])
      cli(["exec", worker, "env", "PGDATABASE=#{target}", "/ops/restore", "/tmp/encrypted.dump"])
      assert_content(db, target, count)
    end

    assert sql(db, "SELECT count(*) FROM pg_database WHERE datname LIKE 'sikio_verify_%'") == "0"
  end

  defp assert_content(db, target, count) do
    assert sql(db, "SELECT username FROM users", target) == "container_restore_probe"
    assert sql(db, "SELECT count(*) FROM schema_migrations", target) == count
  end
end

Sikio.Operations.ContainerSmoke.main()
