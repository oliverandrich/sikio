defmodule Sikio.Operations.BackupTest do
  use ExUnit.Case, async: true
  import Bitwise

  @scripts Path.expand("../../scripts", __DIR__)

  setup do
    directory =
      Path.join(System.tmp_dir!(), "sikio-backup-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    stub(
      directory,
      "pg_dump",
      ~S|for arg in "$@"; do case "$arg" in --file=*) printf archive > "${arg#--file=}";; esac; done|
    )

    stub(directory, "pg_restore", ~s(echo "$*" >> "$CALLS"))
    stub(directory, "psql", ~s(echo "${TABLE_COUNT:-0}"))

    env = [
      {"PATH", directory <> ":" <> System.get_env("PATH")},
      {"PGDATABASE", "restore_test"},
      {"CALLS", Path.join(directory, "calls")},
      {"TABLE_COUNT", "0"}
    ]

    %{directory: directory, env: env, target: Path.join(directory, "backup.dump")}
  end

  test "backup is private and refuses to overwrite", %{env: env, target: target} do
    assert {_, 0} = run("backup", target, env)
    assert band(File.stat!(target).mode, 0o777) == 0o600
    assert {_, code} = run("backup", target, env)
    assert code != 0
    assert File.read!(target) == "archive"
  end

  test "failed dump leaves no finished backup", %{directory: directory, env: env, target: target} do
    stub(directory, "pg_dump", "exit 1")
    assert {_, code} = run("backup", target, env)
    assert code != 0
    refute File.exists?(target)
    assert Path.wildcard(target <> ".partial.*") == []
  end

  test "restore refuses populated databases", %{directory: directory, env: env, target: target} do
    File.write!(target, "archive")
    env = List.keyreplace(env, "TABLE_COUNT", 0, {"TABLE_COUNT", "1"})
    assert {_, code} = run("restore", target, env)
    assert code != 0
    refute File.exists?(Path.join(directory, "calls"))
  end

  test "restore is atomic and stops on errors", %{directory: directory, env: env, target: target} do
    File.write!(target, "archive")
    assert {_, 0} = run("restore", target, env)
    args = File.read!(Path.join(directory, "calls"))
    assert args =~ "--single-transaction"
    assert args =~ "--exit-on-error"
    refute args =~ "--clean"
  end

  defp run(script, target, env) do
    System.cmd(Path.join(@scripts, script), [target], env: env, stderr_to_stdout: true)
  end

  defp stub(directory, name, body) do
    path = Path.join(directory, name)
    File.write!(path, "#!/usr/bin/env bash\nset -eu\n" <> body <> "\n")
    File.chmod!(path, 0o700)
  end
end
