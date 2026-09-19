Code.require_file("../../scripts/operations/backup_runner.exs", __DIR__)

defmodule Sikio.Operations.BackupRunnerTest do
  use ExUnit.Case, async: true

  alias Sikio.Operations.BackupRunner, as: Runner
  alias Sikio.Operations.Support

  @snapshot String.duplicate("a", 64)

  setup do
    root = Path.join(System.tmp_dir!(), "sikio-runner-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    password = Path.join(root, "password")
    File.write!(password, "test-only-password")
    File.chmod!(password, 0o600)

    env = %{
      "PGDATABASE" => "sikio",
      "SIKIO_BACKUP_ID" => "test-instance",
      "RESTIC_REPOSITORY" => Path.join(root, "repository"),
      "RESTIC_PASSWORD_FILE" => password,
      "SIKIO_BACKUP_STATE_DIR" => Path.join(root, "state"),
      "SIKIO_REMOTE_REPOSITORY" => Path.join(root, "remote")
    }

    %{env: env}
  end

  test "backup copies before retention and records offsite success", %{env: env} do
    run = fn args, connection, _options ->
      send(self(), {:command, args, connection})

      if "--json" in args,
        do: JSON.encode!(%{message_type: "summary", snapshot_id: @snapshot}),
        else: ""
    end

    assert %{"offsite" => true, "snapshot" => @snapshot} = Runner.execute("backup", env, run)

    commands =
      for _ <- 1..5 do
        assert_receive {:command, args, connection}
        {args, connection}
      end

    assert [
             {[backup, _], _},
             {["restic", "backup" | _], _},
             {["restic", "copy" | _], _},
             {remote_forget, remote},
             {local_forget, local}
           ] = commands

    assert Path.basename(backup) == "backup"
    assert remote["RESTIC_REPOSITORY"] == env["SIKIO_REMOTE_REPOSITORY"]
    assert local["RESTIC_REPOSITORY"] == env["RESTIC_REPOSITORY"]

    for command <- [remote_forget, local_forget] do
      assert ["restic", "forget" | flags] = command

      assert flags == [
               "--host",
               "test-instance",
               "--tag",
               "sikio",
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
             ]
    end

    assert %{"backup" => %{"offsite" => true, "success_at" => _}} = status(env)
  end

  test "failed copy preserves snapshots and records failure", %{env: env} do
    run = fn args, connection, options ->
      if "copy" in args, do: raise(Support.CommandError)
      fake_run(args, connection, options)
    end

    assert_raise Support.CommandError, fn -> Runner.execute("backup", env, run) end
    refute_received {:command, ["restic", "forget" | _], _}
    assert %{"backup" => %{"error_at" => _} = backup} = status(env)
    refute Map.has_key?(backup, "success_at")
  end

  test "failed dump never creates or prunes a snapshot", %{env: env} do
    run = fn args, _, _ ->
      send(self(), {:command, args})
      raise Support.CommandError
    end

    assert_raise Support.CommandError, fn -> Runner.execute("backup", env, run) end
    assert_received {:command, [backup, _]}
    assert Path.basename(backup) == "backup"
    refute_received {:command, ["restic" | _]}
    assert status(env)["backup"]["error_at"]
  end

  test "verify cleans up its own database when restore fails", %{env: env} do
    run = fn args, connection, options ->
      if Path.basename(hd(args)) == "restore", do: raise(Support.CommandError)
      fake_run(args, connection, options)
    end

    assert_raise Support.CommandError, fn -> Runner.execute("verify", env, run) end
    assert_received {:command, ["createdb", "--no-password", target], connection}
    assert String.starts_with?(target, "sikio_verify_")
    assert connection["PGDATABASE"] == target
    refute target == env["PGDATABASE"]
    assert_received {:command, ["dropdb", "--no-password", ^target], ^connection}
  end

  test "failed creation never drops a database it did not create", %{env: env} do
    run = fn args, connection, options ->
      if hd(args) == "createdb", do: raise(Support.CommandError)
      fake_run(args, connection, options)
    end

    assert_raise Support.CommandError, fn -> Runner.execute("verify", env, run) end
    refute_received {:command, ["dropdb" | _], _}
  end

  test "without a remote destination backup is explicitly local", %{env: env} do
    result = Runner.execute("backup", Map.delete(env, "SIKIO_REMOTE_REPOSITORY"), &fake_run/3)
    assert result["offsite"] == false
    refute_received {:command, ["restic", "copy" | _], _}
  end

  test "verify checks both repositories and uses the separate verification connection", %{
    env: env
  } do
    env = Map.put(env, "SIKIO_VERIFY_PGHOST", "verification-host")

    assert %{"offsite" => true, "remote_snapshot" => @snapshot} =
             Runner.execute("verify", env, &fake_run/3)

    for _ <- 1..2 do
      assert_receive {:command, ["createdb", "--no-password", target], connection}
      assert connection["PGHOST"] == "verification-host"
      assert_receive {:command, ["dropdb", "--no-password", ^target], ^connection}
    end
  end

  test "status rejects stale runs, errors and missing remote verification", %{env: env} do
    File.mkdir_p!(env["SIKIO_BACKUP_STATE_DIR"])
    fresh = Map.new(~w(backup verify), &{&1, %{"success_at" => Runner.now(), "offsite" => true}})
    write_status(env, fresh)
    assert Runner.check_status(env) == fresh
    old = DateTime.utc_now() |> DateTime.add(-10, :day) |> DateTime.to_iso8601()

    for action <- ~w(backup verify) do
      write_status(env, put_in(fresh, [action, "success_at"], old))
      assert_raise RuntimeError, ~r/too old/, fn -> Runner.check_status(env) end
      write_status(env, put_in(fresh, [action, "error_at"], Runner.now()))
      assert_raise RuntimeError, ~r/no successful/, fn -> Runner.check_status(env) end
    end

    write_status(env, put_in(fresh, ["verify", "offsite"], false))
    assert_raise RuntimeError, ~r/remote copy/, fn -> Runner.check_status(env) end
  end

  test "overlapping jobs do not touch repositories and the lock is reusable", %{env: env} do
    File.mkdir_p!(env["SIKIO_BACKUP_STATE_DIR"])

    Support.with_lock(Path.join(env["SIKIO_BACKUP_STATE_DIR"], "runner.lock"), fn ->
      assert_raise RuntimeError, ~r/lock unavailable/, fn ->
        Runner.execute("backup", env, &fake_run/3)
      end

      refute_received {:command, _, _}
    end)

    assert %{"snapshot" => @snapshot} = Runner.execute("backup", env, &fake_run/3)
  end

  test "invalid configuration stops before any external commands", %{env: env} do
    for changed <- [
          Map.delete(env, "PGDATABASE"),
          Map.put(env, "SIKIO_BACKUP_ID", "../bad"),
          Map.put(env, "RESTIC_REPOSITORY", "relative"),
          Map.put(env, "SIKIO_REMOTE_REPOSITORY", env["RESTIC_REPOSITORY"])
        ] do
      assert_raise RuntimeError, fn -> Runner.execute("backup", changed, &fake_run/3) end
      refute_received {:command, _, _}
    end

    File.chmod!(env["RESTIC_PASSWORD_FILE"], 0o644)

    assert_raise RuntimeError, ~r/private password/, fn ->
      Runner.execute("backup", env, &fake_run/3)
    end
  end

  defp fake_run(args, connection, _options) do
    send(self(), {:command, args, connection})

    cond do
      "snapshots" in args -> JSON.encode!([%{id: @snapshot}])
      "--json" in args -> JSON.encode!(%{message_type: "summary", snapshot_id: @snapshot})
      hd(args) == "psql" -> "t\n"
      true -> ""
    end
  end

  defp status(env) do
    env["SIKIO_BACKUP_STATE_DIR"] |> Path.join("status.json") |> File.read!() |> JSON.decode!()
  end

  defp write_status(env, status) do
    File.write!(Path.join(env["SIKIO_BACKUP_STATE_DIR"], "status.json"), JSON.encode!(status))
  end
end
