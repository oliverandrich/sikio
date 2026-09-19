defmodule Sikio.Operations.Support do
  @moduledoc "Small standard-library helpers for standalone operational scripts."
  import Bitwise

  defmodule CommandError do
    defexception message: "External command failed; inspect configuration and service logs."
  end

  def token(bytes \\ 12), do: Base.encode16(:crypto.strong_rand_bytes(bytes), case: :lower)

  def temporary(fun) do
    path = Path.join(System.tmp_dir!(), "sikio-ops-" <> token())
    File.mkdir!(path)
    File.chmod!(path, 0o700)

    try do
      fun.(path)
    after
      File.rm_rf!(path)
    end
  end

  def run([command | args], env, options \\ []) do
    temporary(fn directory ->
      error = Path.join(directory, "stderr")
      opts = [env: Enum.to_list(env)] ++ Keyword.take(options, [:cd])

      opts =
        if options[:stdout],
          do: Keyword.put(opts, :into, File.stream!(options[:stdout], [:write, :binary])),
          else: opts

      {output, status} =
        System.cmd(
          "sh",
          [
            "-c",
            ~s(error=$1; shift; exec "$@" 2>"$error"),
            "sikio-command",
            error,
            command | args
          ],
          opts
        )

      if status != 0, do: raise(CommandError)
      if options[:stdout], do: "", else: output
    end)
  end

  def private_write(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o600)
  end

  def private_file?(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} -> band(mode, 0o077) == 0
      _ -> false
    end
  end

  # An OS-owned advisory lock is released even when the BEAM is killed. The helper
  # holds it until its stdin closes; no PID files or stale lock recovery are needed.
  def with_lock(path, fun) do
    private_write_unless_present(path)

    {command, args} =
      case :os.type() do
        {:unix, :darwin} -> {"lockf", ["-k", "-t", "0", path]}
        {:unix, _} -> {"flock", ["--nonblock", path]}
      end

    executable = System.find_executable(command) || raise "Install #{command} for backup locking"

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 256},
        args: args ++ ["sh", "-c", "echo locked; read release"]
      ])

    try do
      receive do
        {^port, {:data, {:eol, "locked"}}} -> fun.()
        {^port, _} -> raise "Backup lock unavailable"
      after
        5_000 -> raise "Backup lock timed out"
      end
    after
      release_lock(port)
    end
  end

  defp release_lock(port) do
    if Port.info(port) do
      Port.command(port, "release\n")

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        5_000 -> Port.close(port)
      end
    end
  end

  defp private_write_unless_present(path) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, file} -> File.close(file)
      {:error, :eexist} -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "create lock", path: path
    end

    File.chmod!(path, 0o600)
  end
end
