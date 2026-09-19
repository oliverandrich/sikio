Code.require_file("support.exs", __DIR__)

defmodule Sikio.Operations.BackupRunner do
  @moduledoc "Encrypted backups and isolated restore checks without starting Phoenix."
  alias Sikio.Operations.Support

  @ops Path.expand("..", __DIR__)
  # Every table the restore check requires to be present afterwards. Ithibati 0.4 keeps more
  # than the prototype's version did, and Oban brought its own.
  @tables ~w(users invitations feeds entries subscriptions playback_states
             ithibati_bootstrap ithibati_keys ithibati_recovery_codes ithibati_sessions
             ithibati_challenges oban_jobs schema_migrations)

  def now, do: DateTime.to_iso8601(DateTime.utc_now())
  def filters(env), do: ["--host", env["SIKIO_BACKUP_ID"], "--tag", "sikio"]

  def remote_env(env) do
    Map.merge(env, %{
      "RESTIC_REPOSITORY" => env["SIKIO_REMOTE_REPOSITORY"],
      "RESTIC_PASSWORD_FILE" => env["SIKIO_REMOTE_PASSWORD_FILE"] || env["RESTIC_PASSWORD_FILE"]
    })
  end

  def execute(action, env, run \\ &Support.run/3) when action in ["backup", "verify"] do
    validate!(env)
    directory = env["SIKIO_BACKUP_STATE_DIR"]
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)

    Support.with_lock(Path.join(directory, "runner.lock"), fn ->
      path = Path.join(directory, "status.json")
      status = if File.exists?(path), do: path |> File.read!() |> JSON.decode!(), else: %{}

      try do
        result =
          case action do
            "backup" -> backup(env, run)
            "verify" -> verify(env, run)
          end

        result = Map.put(result, "success_at", now())
        write_status(path, Map.put(status, action, result))
        result
      rescue
        error ->
          failed = Map.put(Map.get(status, action, %{}), "error_at", now())
          write_status(path, Map.put(status, action, failed))
          reraise error, __STACKTRACE__
      end
    end)
  end

  defp write_status(path, status) do
    Support.private_write(path <> ".partial", JSON.encode!(status) <> "\n")
    File.rename!(path <> ".partial", path)
  end

  defp retain(env, run) do
    run.(
      ["restic", "forget"] ++
        filters(env) ++
        [
          "--group-by",
          "host,tags",
          "--keep-last",
          "1",
          "--keep-daily",
          "7",
          "--keep-weekly",
          "4",
          "--keep-monthly",
          "12",
          "--prune"
        ],
      env,
      []
    )
  end

  defp backup(env, run) do
    snapshot =
      Support.temporary(fn directory ->
        run.([Path.join(@ops, "backup"), Path.join(directory, "sikio.dump")], env, [])

        output =
          run.(["restic", "backup", "--json"] ++ filters(env) ++ ["sikio.dump"], env,
            cd: directory
          )

        summary =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&JSON.decode!/1)
          |> Enum.filter(&(&1["message_type"] == "summary"))
          |> List.last()

        snapshot = summary && summary["snapshot_id"]

        unless is_binary(snapshot) and Regex.match?(~r/\A[a-f0-9]{64}\z/, snapshot),
          do: raise("No completed snapshot")

        snapshot
      end)

    offsite = present?(env, "SIKIO_REMOTE_REPOSITORY")

    if offsite do
      remote = remote_env(env)

      run.(
        [
          "restic",
          "copy",
          "--from-repo",
          env["RESTIC_REPOSITORY"],
          "--from-password-file",
          env["RESTIC_PASSWORD_FILE"]
        ] ++ filters(env),
        remote,
        []
      )

      retain(remote, run)
    end

    retain(env, run)
    %{"snapshot" => snapshot, "offsite" => offsite}
  end

  defp verify(env, run) do
    result = %{"snapshot" => verify_repository(env, run), "offsite" => false}

    if present?(env, "SIKIO_REMOTE_REPOSITORY") do
      Map.merge(result, %{
        "remote_snapshot" => verify_repository(remote_env(env), run),
        "offsite" => true
      })
    else
      result
    end
  end

  defp verify_repository(env, run) do
    run.(["restic", "check", "--read-data"], env, [])

    snapshots =
      run.(["restic", "snapshots", "--json", "--latest", "1"] ++ filters(env), env, [])
      |> JSON.decode!()

    [%{"id" => snapshot}] = snapshots
    target = "sikio_verify_" <> Support.token(10)

    pg_env =
      Enum.reduce(~w(PGHOST PGPORT PGUSER PGPASSWORD PGPASSFILE), env, fn key, acc ->
        if env["SIKIO_VERIFY_" <> key],
          do: Map.put(acc, key, env["SIKIO_VERIFY_" <> key]),
          else: acc
      end)
      |> Map.put("PGDATABASE", target)

    Support.temporary(fn directory ->
      archive = Path.join(directory, "sikio.dump")
      Support.private_write(archive, "")
      run.(["restic", "dump", snapshot, "/sikio.dump"], env, stdout: archive)
      run.(["createdb", "--no-password", target], pg_env, [])

      try do
        run.([Path.join(@ops, "restore"), archive], pg_env, [])
        tables = Enum.map_join(@tables, ",", &"\x27public.#{&1}\x27")

        sql =
          "SELECT bool_and(to_regclass(name) IS NOT NULL) FROM unnest(ARRAY[#{tables}]) AS name"

        valid =
          run.(["psql", "--no-password", "-X", "-v", "ON_ERROR_STOP=1", "-Atc", sql], pg_env, [])

        unless String.trim(valid) == "t", do: raise("Restored schema is incomplete")
        snapshot
      after
        run.(["dropdb", "--no-password", target], pg_env, [])
      end
    end)
  end

  def validate!(env) do
    for key <-
          ~w(PGDATABASE SIKIO_BACKUP_ID RESTIC_REPOSITORY RESTIC_PASSWORD_FILE SIKIO_BACKUP_STATE_DIR) do
      unless present?(env, key), do: raise("Set #{key}")
    end

    unless Regex.match?(~r/\A[a-zA-Z0-9._-]{1,63}\z/, env["SIKIO_BACKUP_ID"]),
      do: raise("Invalid backup ID")

    unless Path.type(env["RESTIC_REPOSITORY"]) == :absolute,
      do: raise("Repository must be an absolute local directory")

    for key <- ~w(RESTIC_PASSWORD_FILE SIKIO_REMOTE_PASSWORD_FILE), present?(env, key) do
      unless Support.private_file?(env[key]),
        do: raise("#{key} must name a private password file (0600)")
    end

    if env["SIKIO_REMOTE_REPOSITORY"] == env["RESTIC_REPOSITORY"],
      do: raise("Repositories must differ")
  end

  def check_status(env) do
    status =
      env["SIKIO_BACKUP_STATE_DIR"] |> Path.join("status.json") |> File.read!() |> JSON.decode!()

    for {action, max_hours} <- [{"backup", 36}, {"verify", 8 * 24}] do
      item = Map.get(status, action, %{})

      if item["error_at"] || !item["success_at"],
        do: raise("#{action}: no successful current run")

      {:ok, time, _} = DateTime.from_iso8601(item["success_at"])

      if DateTime.diff(DateTime.utc_now(), time) > max_hours * 3600,
        do: raise("#{action}: last success is too old")

      if present?(env, "SIKIO_REMOTE_REPOSITORY") && !item["offsite"],
        do: raise("#{action}: remote copy has not been checked")
    end

    status
  end

  defp present?(env, key), do: env[key] not in [nil, ""]

  def main(args) do
    env = System.get_env()

    result =
      case args do
        ["status"] -> check_status(env)
        [action] when action in ["backup", "verify"] -> execute(action, env)
        _ -> raise "Usage: backup_runner backup|verify|status"
      end

    IO.puts(JSON.encode!(result))
  rescue
    _error ->
      IO.puts(
        :stderr,
        "Backup operation failed. Check configuration, service logs and status.json."
      )

      System.halt(1)
  end
end
