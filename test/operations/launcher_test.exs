defmodule Sikio.Operations.LauncherTest do
  use ExUnit.Case, async: true

  @launcher Path.expand("../../scripts/backup_runner", __DIR__)

  test "release launcher handles version metadata without a newline and paths with spaces" do
    directory =
      Path.join(System.tmp_dir!(), "sikio launcher #{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)
    ops = Path.join(directory, "ops")
    version = Path.join(directory, "releases/0.1.0")
    File.mkdir_p!(ops)
    File.mkdir_p!(version)
    File.cp!(@launcher, Path.join(ops, "backup_runner"))
    File.chmod!(Path.join(ops, "backup_runner"), 0o700)
    File.write!(Path.join(directory, "releases/start_erl.data"), "17.0.6 0.1.0")
    stub = Path.join(version, "elixir")
    File.write!(stub, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
    File.chmod!(stub, 0o700)

    assert {output, 0} =
             System.cmd(Path.join(ops, "backup_runner"), ["status"], stderr_to_stdout: true)

    assert String.split(output, "\n", trim: true) == [
             "--boot",
             ops <> "/../releases/0.1.0/start_clean",
             "--boot-var",
             "RELEASE_LIB",
             ops <> "/../lib",
             ops <> "/backup_runner.exs",
             "status"
           ]
  end
end
